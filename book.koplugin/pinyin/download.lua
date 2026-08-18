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

-- 子进程中校验、拼接并原子落位，避免大文件 IO 阻塞 UI。
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
    local function report(...)
        if on_progress then
            on_progress(...)
        end
    end
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
        local attr = lfs.attributes(dest)
        local settings = MoonSettings.get()
        if attr and attr.mode == "file" and (attr.size or 0) > 0
            and (not manifest.raw_size or attr.size == tonumber(manifest.raw_size))
            and manifest.raw_sha256 and settings.pinyin_dict_sha256 == manifest.raw_sha256 then
            done(true)
            return
        end
        local total = 0
        for _, p in ipairs(manifest.parts) do
            total = total + (tonumber(p.size) or 0)
        end
        report("manifest", 0, total, 0, #manifest.parts)
        Paths.ensureSettings() -- 内含 ensureDir(root)
        lfs.mkdir(tmpDir())
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
            require("pinyin.dictionary").reset()
            local c = MoonSettings.get()
            c.pinyin_dict_source = manifest.tag or "unknown"
            c.pinyin_dict_sha256 = manifest.raw_sha256
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

--- 中止当前网络或拼接任务，并清理临时分片。
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
