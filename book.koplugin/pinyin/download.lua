--[[--
拼音词库下载：manifest + 分片下载 → 子进程解压拼接 → 校验落位。

词库产物在仓库 assets/pinyin/（tools/build_pinyin_dict.py 生成）：

  manifest.json                { tag, built_at, entries, raw_sha256, raw_size, parts:[{file,size}] }
  dictionary.sqlite3.gz.NNN    每片独立 gzip，按序 inflate 解压拼出原始 sqlite

设备经 jsdelivr 按仓库文件拉取；整库 gzip 超 jsdelivr ~20MB 单文件上限，所以切片。
下载逐片走 Request.download（Turbo，不堵 UI）；解压/sha256/落位放 Task 子进程
（CPU 密集 + 大文件 IO，主进程做会卡 UI）。

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

--- 子进程：逐片 inflate 解压拼接 → 校验 raw sha256 → 原子落位。
--- fork 复制主进程内存，闭包上值（manifest/dir/dest）安全；返回 nil 或错误串。
---@param manifest table
---@param dir string
---@param dest string
---@return string|nil
local function assemble(manifest, dir, dest)
    local Gz = require("pinyin.gzinflate")
    local sha = require("ffi/sha2")
    local out_tmp = dest .. ".part"
    local ok, err = pcall(function()
        local out = assert(io.open(out_tmp, "wb"))
        for _, part in ipairs(manifest.parts) do
            local f = assert(io.open(dir .. "/" .. part.file, "rb"))
            local gz = f:read("*a")
            f:close()
            out:write(Gz.inflateGzip(gz))
        end
        out:close()
        -- 校验：整库读回内存一次（子进程内存独立，峰值可接受）
        local f = assert(io.open(out_tmp, "rb"))
        local raw = f:read("*a")
        f:close()
        if sha.sha256(raw) ~= manifest.raw_sha256 then
            error("sha256 mismatch")
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
function M.ensure(cb, force)
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
        downloadParts(manifest, 1, dest, done)
    end)
end

-- 前向声明的实现
downloadParts = function(manifest, idx, dest, done)
    local parts = manifest.parts
    if idx > #parts then
        assembleInTask(manifest, dest, done)
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
    }, tmpDir() .. "/" .. part.file, function(ok, err)
        if not ok then
            cleanupTmp()
            done(false, err)
            return
        end
        downloadParts(manifest, idx + 1, dest, done)
    end)
end

assembleInTask = function(manifest, dest, done)
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
