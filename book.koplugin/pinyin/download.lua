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

-- 与 ui/desktop/settings.lua 的 REPO_HOST 同仓库；jsdelivr 按仓库 main 拉原始文件
local BASE_URL = "https://cdn.jsdelivr.net/gh/AnkioTomas/moon@main/assets/pinyin"

local M = {}

local _job -- 当前在飞 job（Request job 或 Task job）
local _downloading = false

-- 前向声明：ensure → downloadParts → assembleInTask 链式互调
local downloadParts
local assembleInTask

---@return boolean
function M.downloading()
    return _downloading
end

--- 进度回报（可选）：stage = "manifest" | "part" | "assemble"。
--- part 阶段带字节进度（done/total）与分片序号（idx/count）；其余阶段只有 stage。
---@param on_progress fun(stage: string, done: number|nil, total: number|nil, idx: number|nil, count: number|nil)|nil
---@return fun(...)
local function makeReporter(on_progress)
    return function(...)
        if on_progress then
            pcall(on_progress, ...)
        end
    end
end

---@return string
local function tmpDir()
    return Paths.root() .. "/pinyin_dict.dl"
end

local function cleanupTmp()
    local dir = tmpDir()
    for f in lfs.dir(dir) do
        if f ~= "." and f ~= ".." then
            os.remove(dir .. "/" .. f)
        end
    end
    os.remove(dir)
end

--- 子进程：逐片校验后直接拼接 → 校验总长度 → 原子落位。
--- fork 复制主进程内存，闭包上值（manifest/dir/dest）安全；返回 nil 或错误串。
---@param manifest table
---@param dir string
---@param dest string
---@return string|nil
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
                error("part sha256 mismatch: " .. part.file)
            end
            assert(out:write(data))
            total = total + #data
        end
        out:close()
        if manifest.raw_size and total ~= tonumber(manifest.raw_size) then
            error(string.format("size mismatch: got %d, want %d", total, manifest.raw_size))
        end
        os.remove(dest)
        assert(os.rename(out_tmp, dest))
    end)
    if not ok then
        os.remove(out_tmp)
        return tostring(err)
    end
    return nil
end

--- 下载主流程。已下载且文件在 → 直接 cb(true)；force=true 强制按 manifest 重拉。
---@param cb fun(ok: boolean, err: any)|nil
---@param force boolean|nil
---@param on_progress fun(stage: string, done: number|nil, total: number|nil, idx: number|nil, count: number|nil)|nil
function M.ensure(cb, force, on_progress)
    cb = cb or function() end
    if _downloading then
        cb(false, "already downloading")
        return
    end
    local dest = Paths.pinyinDictPath()
    if not force then
        local attr = lfs.attributes(dest)
        if attr and attr.mode == "file" and (attr.size or 0) > 0 then
            cb(true)
            return
        end
    end
    _downloading = true
    local report = makeReporter(on_progress)
    local done_called = false
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
        if not ok or type(manifest) ~= "table" or type(manifest.parts) ~= "table"
            or #manifest.parts == 0 then
            done(false, "bad manifest")
            return
        end
        local total = 0
        for _, p in ipairs(manifest.parts) do
            total = total + (tonumber(p.size) or 0)
        end
        report("manifest", 0, total, 0, #manifest.parts)
        downloadParts(manifest, 1, dest, done, report, 0, total)
    end)
end

-- 前向声明的实现
downloadParts = function(manifest, idx, dest, done, report, done_bytes, total)
    local parts = manifest.parts
    if idx > #parts then
        assembleInTask(manifest, dest, done, report)
        return
    end
    lfs.mkdir(Paths.root())
    Paths.ensureSettings() -- 递归建好 .moon 树，tmpDir 在 .moon 下
    lfs.mkdir(tmpDir())
    local part = parts[idx]
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
            cleanupTmp()
            done(false, err)
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
            -- 词库文件已换：清字典模块的连接/负缓存，设置页状态与候选立即可见新库
            pcall(function()
                require("pinyin.dictionary").reset()
            end)
            local c = MoonSettings.get()
            c.pinyin_dict_source = manifest.tag or "unknown"
            MoonSettings.save()
            logger.info("book.pinyin dict installed:", manifest.tag, manifest.entries)
            done(true)
        end,
        on_failed = function(err)
            cleanupTmp()
            logger.warn("book.pinyin dict assemble failed:", err)
            done(false, err)
        end,
    })
end

--- 中止在飞下载。
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
    cleanupTmp()
end

return M
