--[[--
中文输入法词库下载：manifest + 原始分片下载 → 子进程拼接 → 校验落位。

拼音产物在 assets/pinyin/，其余产物在 assets/ime/<method>/。

  manifest.json                { tag, built_at, entries, raw_sha256, raw_size, parts:[{file,size,sha256}] }
  dictionary.sqlite3.part.NNN  原始 SQLite 二进制分片，按序拼出原始 sqlite

设备经 http.mirror 按仓库文件拉取（多源回落）；jsDelivr 单文件有大小上限，所以切片。
下载逐片走 Mirror.download（Turbo，不堵 UI）；拼接/分片 SHA-256/落位放 Job 子进程
（大文件 IO，主进程做会卡 UI）。

落盘文件名由 Paths.imeDictPath 决定。生僻字注音词库（features.rare）复用 ``M.install``，同一套 manifest + 分片格式。

@module koplugin.book.features.ime.download
--]]

local lfs = require("libs/libkoreader-lfs")
local logger = require("utils.log")
local JSON = require("json")
local Mirror = require("http.mirror")
local Paths = require("utils.paths")
local Perf = require("utils.perf")
local MoonSettings = require("utils.settings")
local Job = require("workers.job")

-- 拼音保留旧仓库路径，避免已发布插件访问 main 时失效。
local BASE_ROOT = "assets"

local M = {
    _downloading = false,
}

-- 下载和拼接相互递归，先声明以保持主流程顺序。
local downloadParts
local assembleInJob

--- 是否有下载或拼接任务在运行。
function M.downloading()
    return M._downloading
end

--- 分片续传用的临时目录。
---@param spec BookDictSpec
---@return string
local function tmpDir(spec)
    return spec.tmp or spec.dest .. ".dl"
end

--- 删掉临时目录及其中全部分片；目录不存在时无操作。
local function cleanupTmp(spec)
    local dir = tmpDir(spec)
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

---@return boolean
local function isSha256(value)
    return type(value) == "string" and #value == 64 and value:match("^[%da-fA-F]+$") ~= nil
end

---@return boolean
local function isPositiveInteger(value)
    local n = tonumber(value)
    return n ~= nil and n > 0 and n < math.huge and n == math.floor(n)
end

--- 验证不受本地控制的远程 manifest，避免路径逃逸和坏数据把下载状态机卡死。
---@return boolean, string|nil, number|nil
local function validateManifest(manifest)
    if type(manifest) ~= "table" or type(manifest.built_at) ~= "string" or manifest.built_at == ""
        or not isSha256(manifest.raw_sha256) or not isPositiveInteger(manifest.raw_size)
        or type(manifest.parts) ~= "table" or #manifest.parts == 0 then
        return false, "bad manifest"
    end
    local total = 0
    for _idx, part in ipairs(manifest.parts) do
        if type(part) ~= "table" or type(part.file) ~= "string"
            or not part.file:match("^[%w._%-]+$") or not isPositiveInteger(part.size)
            or not isSha256(part.sha256) then
            return false, "bad manifest part"
        end
        total = total + tonumber(part.size)
    end
    if total ~= tonumber(manifest.raw_size) then
        return false, "manifest size mismatch"
    end
    return true, nil, total
end

--- 记下本批分片对应的 manifest 版本；版本对不上先清空续传目录。
--- 临时分片必须属于同一版 manifest，不能把新旧词库拼在一起。
---@param manifest table 至少含 built_at 与 raw_sha256
---@return boolean, string|nil
local function syncTmpManifest(manifest, spec)
    local path = tmpDir(spec) .. "/.manifest.json"
    local f = io.open(path, "rb")
    if f then
        local body = f:read("*a")
        f:close()
        local ok, saved = pcall(JSON.decode, body)
        if not ok or type(saved) ~= "table"
            or saved.built_at ~= manifest.built_at
            or saved.raw_sha256 ~= manifest.raw_sha256 then
            cleanupTmp(spec)
        end
    end
    if lfs.attributes(tmpDir(spec), "mode") ~= "directory" and not lfs.mkdir(tmpDir(spec)) then
        return false, "cannot create dictionary temp directory"
    end
    local encoded = JSON.encode({
        built_at = manifest.built_at,
        raw_sha256 = manifest.raw_sha256,
    })
    local write_file, open_err = io.open(path, "wb")
    if not write_file then
        return false, open_err or "cannot write dictionary manifest"
    end
    local wrote, write_err = write_file:write(encoded)
    local closed, close_err = write_file:close()
    if not wrote or not closed then
        os.remove(path)
        return false, write_err or close_err or "cannot write dictionary manifest"
    end
    return true
end

--- 分片是否已完整落在临时目录（只比字节数，内容由拼接期 sha256 把关）。
---@param part table manifest 分片项（file / size）
---@return boolean
local function partComplete(part, spec)
    local attr = lfs.attributes(tmpDir(spec) .. "/" .. part.file)
    return attr and attr.mode == "file" and attr.size == tonumber(part.size)
end

--- 逐片校验 sha256 后拼成整库，核对总长度再改名落位。
--- 子进程中校验、拼接并原子落位，避免大文件 IO 阻塞 UI。
--- 校验不过只删坏片（其余分片留着续传），并清掉半截目标文件。
---@param manifest table 含 parts / raw_size
---@param dir string 分片所在目录
---@param dest string 目标词库路径
---@param progress fun(bytes: number) 已处理字节；每变化 1% 调一次（经管道回主进程，不能每块都发）
---@return string|nil 出错信息，成功为 nil
local function assemble(manifest, dir, dest, progress)
    local out_tmp = dest .. ".part"
    local ok, err = pcall(function()
        local out = assert(io.open(out_tmp, "wb"))
        local total = 0
        local step = math.max(1, math.floor(tonumber(manifest.raw_size) / 100))
        local next_report = step
        local sha256 = require("ffi/sha2").sha256
        local full_hash = sha256()
        for _idx, part in ipairs(manifest.parts) do
            local f = assert(io.open(dir .. "/" .. part.file, "rb"))
            local part_hash = sha256()
            -- 读写出错也要先关两个句柄再抛
            local read_ok, read_fail = pcall(function()
                while true do
                    local data, read_err = f:read(256 * 1024)
                    if not data then
                        assert(not read_err, read_err)
                        break
                    end
                    part_hash(data)
                    full_hash(data)
                    assert(out:write(data))
                    total = total + #data
                    if total >= next_report then
                        progress(total)
                        next_report = total + step
                    end
                end
            end)
            f:close()
            if not read_ok then
                out:close()
                error(read_fail, 0)
            end
            if part_hash() ~= part.sha256:lower() then
                -- 只丢掉坏片，保留其它已完成分片供下次续传。
                out:close()
                os.remove(dir .. "/" .. part.file)
                error("part sha256 mismatch: " .. part.file)
            end
        end
        assert(out:close())
        if total ~= tonumber(manifest.raw_size) then
            error(string.format("size mismatch: got %d, want %d", total, manifest.raw_size))
        end
        if full_hash() ~= manifest.raw_sha256:lower() then
            error("dictionary sha256 mismatch")
        end
        assert(os.rename(out_tmp, dest))
    end)
    if not ok then
        os.remove(out_tmp)
        return tostring(err)
    end
    return nil
end

--- 一份可下载词库的描述。
---@class BookDictSpec
---@field name string 日志与 Job 名
---@field base_path string manifest.json 与分片所在的仓库内目录（经 http.mirror 取）
---@field dest string 落盘路径（续传目录为 dest .. ".dl"）
---@field installed string|nil 已装版本的 built_at
---@field tmp string|nil 续传目录，缺省 dest .. ".dl"
---@field on_installed fun(manifest: table) 落位成功后记版本、重置缓存

--- 拉并校验远端 manifest。成功 cb(manifest, 总字节)，失败 cb(nil, nil, err)。
---@param spec { base_path: string }
---@param cb fun(manifest: table|nil, total: number|nil, err: any)
local function fetchManifest(spec, cb)
    Mirror.get(spec.base_path .. "/manifest.json", { timeout = require("http.timeout").net(1) }, function(body, err)
        if err then
            cb(nil, nil, err)
            return
        end
        local ok, manifest = pcall(JSON.decode, body)
        if not ok then
            cb(nil, nil, "bad manifest")
            return
        end
        local valid, manifest_err, total = validateManifest(manifest)
        if not valid then
            cb(nil, nil, manifest_err)
            return
        end
        cb(manifest, total)
    end)
end

--- 远端 manifest 的版本和已装的不一样（只查版本，不下载分片）。cb(true|false)，查询失败 cb(nil, err)。
---@param spec { base_path: string, installed?: string }
---@param cb fun(outdated: boolean|nil, err: any)
function M.outdated(spec, cb)
    fetchManifest(spec, function(manifest, _total, err)
        if err then
            cb(nil, err)
            return
        end
        cb(spec.installed ~= manifest.built_at)
    end)
end

--- 按 manifest 下载有更新的分片并落位。重复请求通过 cb 返回失败，不并发写同一目标。
---@param spec BookDictSpec
---@param cb fun(ok: boolean, err: any)|nil
---@param on_progress fun(stage: string, done: number|nil, total: number|nil, idx: number|nil, count: number|nil)|nil
function M.install(spec, cb, on_progress)
    cb = cb or function() end
    if M._downloading then
        cb(false, "already downloading")
        return
    end
    local dest = spec.dest
    local started_at = Perf.now()
    M._downloading = true
    logger.dbg("book dict download start", spec.name, dest)
    --- 转发进度给调用方（未传 on_progress 时静默丢弃）。
    ---@param ... any 阶段名及可选的进度数值
    local function report(...)
        if on_progress then
            on_progress(...)
        end
    end
    --- 收尾：解掉在飞标记并回调。
    ---@param ok boolean
    local function done(ok, err)
        M._downloading = false
        if ok then
            logger.dbg("book dict download done", spec.name, Perf.elapsedMs(started_at), "ms")
        else
            logger.warn("book dict download failed", spec.name, Perf.elapsedMs(started_at), "ms", err)
        end
        cb(ok, err)
    end

    report("manifest")
    fetchManifest(spec, function(manifest, total, err)
        if err then
            done(false, err)
            return
        end
        local attr = lfs.attributes(dest)
        if attr and attr.mode == "file" and attr.size == tonumber(manifest.raw_size)
            and spec.installed == manifest.built_at then
            done(true)
            return
        end
        report("manifest", 0, total, 0, #manifest.parts)
        Paths.ensureDir(Paths.root())
        local synced, sync_err = syncTmpManifest(manifest, spec)
        if not synced then
            done(false, sync_err)
            return
        end
        downloadParts(spec, manifest, 1, done, report, 0, total)
    end)
end

--- 输入法词库的下载规格。
---@param method "pinyin"|"wubi"|"cangjie"|"zhuyin"
---@return BookDictSpec
function M.imeSpec(method)
    return {
        name = "ime." .. method,
        base_path = BASE_ROOT .. (method == "pinyin" and "/pinyin" or "/ime/" .. method),
        dest = Paths.imeDictPath(method),
        tmp = Paths.root() .. "/ime_" .. method .. "_dict.dl",
        installed = MoonSettings.get("features.ime").ime_dict_built_at[method],
        on_installed = function(manifest)
            require("features.ime.registry").reset(method)
            local c = MoonSettings.get("features.ime")
            c.ime_dict_built_at[method] = manifest.built_at
            MoonSettings.save("features.ime", c)
            logger.info("book ime dict installed:", method, manifest.tag, manifest.entries)
        end,
    }
end

--- 输入法词库：按方法 id 拼出 spec 交给 install。
---@param method "pinyin"|"wubi"|"cangjie"|"zhuyin"
---@param cb fun(ok: boolean, err: any)|nil
---@param on_progress function|nil
function M.ensure(method, cb, on_progress)
    M.install(M.imeSpec(method), cb, on_progress)
end

-- 前向声明的实现。
downloadParts = function(spec, manifest, idx, done, report, done_bytes, total)
    local parts = manifest.parts
    if idx > #parts then
        assembleInJob(spec, manifest, done, report)
        return
    end
    local part = parts[idx]
    if partComplete(part, spec) then
        local size = tonumber(part.size)
        report("part", done_bytes + size, total, idx, #parts)
        downloadParts(spec, manifest, idx + 1, done, report, done_bytes + size, total)
        return
    end
    -- 网络响应尚未返回时也先通知当前分片，避免进度框长时间停在上一阶段。
    report("part", done_bytes, total, idx, #parts)
    local file = tmpDir(spec) .. "/" .. part.file
    Mirror.download(spec.base_path .. "/" .. part.file, {
        timeout = require("http.timeout").net(10),
        allow_redirects = true,
        on_progress = total > 0 and function(written)
            report("part", done_bytes + written, total, idx, #parts)
        end or nil,
        check = function()
            if partComplete(part, spec) then return true end
            return false, "part size mismatch: " .. part.file
        end,
    }, file, function(ok, err)
        if not ok then
            done(false, err)
            return
        end
        downloadParts(spec, manifest, idx + 1, done, report, done_bytes + tonumber(part.size), total)
    end)
end

assembleInJob = function(spec, manifest, done, report)
    local size, count = tonumber(manifest.raw_size), #manifest.parts
    report("assemble", 0, size, nil, count)
    local dir = tmpDir(spec)
    Job.run(function(progress)
        local err = assemble(manifest, dir, spec.dest, progress)
        if err then
            error(err)
        end
    end, {
        name = "features." .. spec.name .. ".assemble",
        -- medium 每 2s 收一次管道：进度条要能看出在动，heavy 的 5s 太钝。
        kind = "medium",
        timeout = require("http.timeout").net(10),
        on_progress = function(bytes)
            report("assemble", bytes, size, nil, count)
        end,
        on_done = function()
            cleanupTmp(spec)
            spec.on_installed(manifest)
            done(true)
        end,
        on_failed = function(err)
            done(false, err)
        end,
    })
end
return M
