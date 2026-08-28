--[[--
拼音词库下载：manifest + 原始分片下载 → 子进程拼接 → 校验落位。

词库产物在仓库 assets/pinyin/（tools/build_pinyin_dict.py 生成）：

  manifest.json                { tag, built_at, entries, raw_sha256, raw_size, parts:[{file,size,sha256}] }
  dictionary.sqlite3.part.NNN  原始 SQLite 二进制分片，按序拼出原始 sqlite

设备经 jsdelivr 按仓库文件拉取；单文件有大小上限，所以切片。
下载逐片走 Request.download（Turbo，不堵 UI）；拼接/分片 SHA-256/落位放 Task 子进程
（大文件 IO，主进程做会卡 UI）。

落盘：$DATA/.moon/dictionary.sqlite3（见 Paths.pinyinDictPath）。

@module koplugin.book.pinyin.download
--]]

local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local JSON = require("json")
local Request = require("http.request")
local Paths = require("utils.paths")
local MoonSettings = require("utils.settings")
local Task = require("utils.task")

-- 与桌面设置页使用同一仓库；jsdelivr 按 main 分发原始分片。
local BASE_URL = "https://cdn.jsdelivr.net/gh/AnkioTomas/moon@main/assets/pinyin"

local M = {}

local _job -- 当前在飞 job（Request job 或 Task job）
local _downloading = false

-- 下载和拼接相互递归，先声明以保持主流程顺序。
local downloadParts
local assembleInTask

--- 是否有下载或拼接任务在运行。
function M.downloading()
    return _downloading
end

--- 分片续传用的临时目录。
---@return string
local function tmpDir()
    return Paths.root() .. "/pinyin_dict.dl"
end

--- 删掉临时目录及其中全部分片；目录不存在时无操作。
local function cleanupTmp()
    local dir = tmpDir()
    local ok, iter, dir_obj = pcall(lfs.dir, dir)
    if not ok or not iter then
        return
    end
    for f in iter, dir_obj do
        if f ~= "." and f ~= ".." then
            os.remove(dir .. "/" .. f)
        end
    end
    os.remove(dir)
end

--- 临时目录里记录本批分片所属 manifest 版本的文件路径。
---@return string
local function tmpManifestPath()
    return tmpDir() .. "/.manifest.json"
end

--- 记下本批分片对应的 manifest 版本；版本对不上先清空续传目录。
--- 临时分片必须属于同一版 manifest，不能把新旧词库拼在一起。
---@param manifest table 至少含 built_at 与 raw_sha256
local function syncTmpManifest(manifest)
    local path = tmpManifestPath()
    local f = io.open(path, "rb")
    if f then
        local body = f:read("*a")
        f:close()
        local ok, saved = pcall(JSON.decode, body)
        if not ok or type(saved) ~= "table"
            or saved.built_at ~= manifest.built_at
            or saved.raw_sha256 ~= manifest.raw_sha256 then
            cleanupTmp()
        end
    end
    lfs.mkdir(tmpDir())
    f = assert(io.open(path, "wb"))
    f:write(JSON.encode({
        built_at = manifest.built_at,
        raw_sha256 = manifest.raw_sha256,
    }))
    f:close()
end

--- 分片是否已完整落在临时目录（只比字节数，内容由拼接期 sha256 把关）。
---@param part table manifest 分片项（file / size）
---@return boolean
local function partComplete(part)
    local attr = lfs.attributes(tmpDir() .. "/" .. part.file)
    return attr and attr.mode == "file" and attr.size == tonumber(part.size)
end

--- 逐片校验 sha256 后拼成整库，核对总长度再改名落位。
--- 子进程中校验、拼接并原子落位，避免大文件 IO 阻塞 UI。
--- 校验不过只删坏片（其余分片留着续传），并清掉半截目标文件。
---@param manifest table 含 parts / raw_size
---@param dir string 分片所在目录
---@param dest string 目标词库路径
---@return string|nil 出错信息，成功为 nil
local function assemble(manifest, dir, dest)
    local out_tmp = dest .. ".part"
    local ok, err = pcall(function()
        local out = assert(io.open(out_tmp, "wb"))
        local total = 0
        local sha256 = require("ffi/sha2").sha256
        for _, part in ipairs(manifest.parts) do
            local f = assert(io.open(dir .. "/" .. part.file, "rb"))
            local data = f:read("*a")
            f:close()
            if part.sha256 and sha256(data) ~= part.sha256 then
                -- 只丢掉坏片，保留其它已完成分片供下次续传。
                os.remove(dir .. "/" .. part.file)
                error("part sha256 mismatch: " .. part.file)
            end
            assert(out:write(data))
            total = total + #data
        end
        out:close()
        if manifest.raw_size and total ~= tonumber(manifest.raw_size) then
            error(string.format("size mismatch: got %d, want %d", total, manifest.raw_size))
        end
        assert(os.rename(out_tmp, dest))
    end)
    if not ok then
        os.remove(out_tmp)
        return tostring(err)
    end
    return nil
end

--- 按 manifest 下载有更新的分片并落位。重复请求通过 cb 返回失败，不并发写同一目标。
---@param cb fun(ok: boolean, err: any)|nil
---@param on_progress fun(stage: string, done: number|nil, total: number|nil, idx: number|nil, count: number|nil)|nil
function M.ensure(cb, on_progress)
    cb = cb or function() end
    if _downloading then
        cb(false, "already downloading")
        return
    end
    local dest = Paths.pinyinDictPath()
    _downloading = true
    --- 转发进度给调用方（未传 on_progress 时静默丢弃）。
    ---@param ... any 阶段名及可选的进度数值
    local function report(...)
        if on_progress then
            on_progress(...)
        end
    end
    local done_called = false
    --- 收尾：解掉在飞标记并回调，只生效一次（多条失败路径可能都调到）。
    ---@param ok boolean
    ---@param err any
    local function done(ok, err)
        if done_called then
            return
        end
        done_called = true
        _downloading = false
        _job = nil
        cb(ok, err)
    end

    report("manifest")
    _job = Request.get(BASE_URL .. "/manifest.json", { timeout = 30 }, function(body, err)
        if err then
            done(false, err)
            return
        end
        local ok, manifest = pcall(JSON.decode, body)
        if not ok or type(manifest) ~= "table" or type(manifest.built_at) ~= "string"
            or manifest.built_at == "" or type(manifest.parts) ~= "table" or #manifest.parts == 0 then
            done(false, "bad manifest")
            return
        end
        local attr = lfs.attributes(dest)
        local settings = MoonSettings.get()
        if attr and attr.mode == "file" and (attr.size or 0) > 0
            and settings.pinyin_dict_built_at == manifest.built_at then
            done(true)
            return
        end
        local total = 0
        for _, p in ipairs(manifest.parts) do
            total = total + (tonumber(p.size) or 0)
        end
        report("manifest", 0, total, 0, #manifest.parts)
        Paths.ensureSettings() -- 内含 ensureDir(root)
        syncTmpManifest(manifest)
        downloadParts(manifest, 1, dest, done, report, 0, total)
    end)
end

-- 前向声明的实现。
downloadParts = function(manifest, idx, dest, done, report, done_bytes, total)
    local parts = manifest.parts
    if idx > #parts then
        assembleInTask(manifest, dest, done, report)
        return
    end
    local part = parts[idx]
    if partComplete(part) then
        local size = tonumber(part.size) or 0
        report("part", done_bytes + size, total, idx, #parts)
        downloadParts(manifest, idx + 1, dest, done, report, done_bytes + size, total)
        return
    end
    _job = Request.download({
        url = BASE_URL .. "/" .. part.file,
        method = "GET",
        timeout = 300,
        allow_redirects = true,
        on_progress = total > 0 and function(written)
            report("part", done_bytes + written, total, idx, #parts)
        end or nil,
    }, tmpDir() .. "/" .. part.file, function(ok, err)
        if not ok then
            os.remove(tmpDir() .. "/" .. part.file)
            done(false, err)
            return
        end
        if not partComplete(part) then
            os.remove(tmpDir() .. "/" .. part.file)
            done(false, "part size mismatch: " .. part.file)
            return
        end
        downloadParts(manifest, idx + 1, dest, done, report,
            done_bytes + (tonumber(part.size) or 0), total)
    end)
end

assembleInTask = function(manifest, dest, done, report)
    report("assemble")
    local dir = tmpDir()
    _job = Task.run(function()
        local err = assemble(manifest, dir, dest)
        if err then
            error(err)
        end
    end, {
        timeout = 300,
        on_done = function()
            cleanupTmp()
            local attr = lfs.attributes(dest)
            if not attr or attr.mode ~= "file" or (attr.size or 0) == 0 then
                logger.warn("book.pinyin dict assemble finished without output:", dest)
                done(false, "dictionary file missing: " .. dest)
                return
            end
            require("pinyin.dictionary").reset()
            local c = MoonSettings.get()
            c.pinyin_dict_built_at = manifest.built_at
            c.pinyin_dict_sha256 = manifest.raw_sha256
            MoonSettings.save()
            logger.info("book.pinyin dict installed:", manifest.tag, manifest.entries)
            done(true)
        end,
        on_failed = function(err)
            logger.warn("book.pinyin dict assemble failed:", err)
            done(false, err)
        end,
    })
end

--- 中止当前网络或拼接任务；保留已完成分片供下次继续。
function M.cancel()
    if _job then
        if _job.abort then
            _job.abort()
        elseif _job.cancel then
            _job.cancel()
        end
    end
    _job = nil
    _downloading = false
end

return M
