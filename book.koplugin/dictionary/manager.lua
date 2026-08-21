--[[--
StarDict 词典管理：清单、分片下载校验、原子安装、切换与受控删除。

只有 `book-<id>` 目录归本插件所有；用户自行安装的词典只允许切换，不允许删除。

@module koplugin.book.dictionary.manager
--]]

local JSON = require("json")
local Request = require("http.request")
local Paths = require("utils.paths")
local Task = require("utils.task")
local lfs = require("libs/libkoreader-lfs")

local Manager = {}
local BASE_URL = "https://cdn.jsdelivr.net/gh/AnkioTomas/moon@main/assets/dict"
local _job
local _downloading = false

local function safeId(value)
    return type(value) == "string" and value:match("^[%w_%-]+$") and value or nil
end

local function validHash(value)
    return type(value) == "string" and #value == 64 and value:match("^%x+$") ~= nil
end

--- 校验远程清单；返回规范化字典项列表。
---@param manifest table
---@return table[]|nil, string|nil
function Manager.validateManifest(manifest)
    if type(manifest) ~= "table" or type(manifest.dictionaries) ~= "table" then
        return nil, "bad manifest"
    end
    local out, seen = {}, {}
    for _, item in ipairs(manifest.dictionaries) do
        if type(item) ~= "table" or not safeId(item.id) or seen[item.id]
            or type(item.name) ~= "string" or item.name == ""
            or tonumber(item.size) == nil or tonumber(item.size) <= 0
            or not validHash(item.sha256) or type(item.parts) ~= "table" or #item.parts == 0 then
            return nil, "bad dictionary manifest"
        end
        local sum = 0
        for _, part in ipairs(item.parts) do
            if type(part) ~= "table" or type(part.file) ~= "string"
                or not part.file:match("^" .. item.id .. "%.part%.%d%d%d$")
                or tonumber(part.size) == nil or tonumber(part.size) <= 0
                or not validHash(part.sha256) then
                return nil, "bad dictionary part"
            end
            sum = sum + tonumber(part.size)
        end
        if sum ~= tonumber(item.size) then return nil, "dictionary size mismatch" end
        seen[item.id] = true
        out[#out + 1] = item
    end
    if #out == 0 then return nil, "empty manifest" end
    return out
end

--- 拉取并校验远程字典目录。
---@param cb fun(items: table[]|nil, err: any)
---@return table
function Manager.catalog(cb)
    return Request.get(BASE_URL .. "/manifest.json", { timeout = 30 }, function(body, err)
        if not body then cb(nil, err); return end
        local ok, manifest = pcall(JSON.decode, body)
        if not ok then cb(nil, manifest); return end
        local items, invalid = Manager.validateManifest(manifest)
        cb(items, invalid)
    end)
end

local function tmpDir(id)
    return Paths.root() .. "/dict-" .. id .. ".dl"
end

local function purge(path)
    return require("ffi/util").purgeDir(path)
end

local function partComplete(dir, part)
    local attr = lfs.attributes(dir .. "/" .. part.file)
    return attr and attr.mode == "file" and attr.size == tonumber(part.size)
end

local function installTarget(data_dir, id)
    return data_dir .. "/book-" .. id
end

--- 是否已安装本插件管理的字典（book-<id> 目录）。
---@param data_dir string
---@param id string
---@return boolean
function Manager.isInstalled(data_dir, id)
    return safeId(id) ~= nil and lfs.attributes(installTarget(data_dir, id), "mode") == "directory"
end

local function assembleAndExtract(item, dir, target)
    local sha256 = require("ffi/sha2").sha256
    local archive = dir .. "/archive.part"
    local output = assert(io.open(archive, "wb"))
    local full, total = {}, 0
    for _, part in ipairs(item.parts) do
        local file = assert(io.open(dir .. "/" .. part.file, "rb"))
        local data = file:read("*a")
        file:close()
        if #data ~= tonumber(part.size) or sha256(data) ~= part.sha256 then
            output:close()
            error("part sha256 mismatch: " .. part.file)
        end
        assert(output:write(data))
        full[#full + 1] = data
        total = total + #data
    end
    output:close()
    if total ~= tonumber(item.size) or sha256(table.concat(full)) ~= item.sha256 then
        error("dictionary sha256 mismatch")
    end
    full = nil

    local staging = target .. ".part"
    purge(staging)
    assert(lfs.mkdir(staging))
    local Archiver = require("ffi/archiver")
    local reader = Archiver.Reader:new()
    if not reader:open(archive) then error(reader.err or "cannot open dictionary archive") end
    local has_ifo = false
    for entry in reader:iterate() do
        local path = entry.path
        if type(path) ~= "string" or path == "" or path:sub(1, 1) == "/"
            or path == ".." or path:match("^%.%./") or path:match("/%.%./")
            or path:match("/%.%.$") then
            reader:close()
            purge(staging)
            error("unsafe archive path")
        end
        if entry.mode == "file" or entry.mode == "directory" then
            if entry.mode == "file" and path:lower():match("%.ifo$") then has_ifo = true end
            if not reader:extractToPath(path, staging .. "/" .. path) then
                local extract_err = reader.err
                reader:close()
                purge(staging)
                error(extract_err or "dictionary extraction failed")
            end
        end
    end
    reader:close()
    if not has_ifo then purge(staging); error("archive contains no StarDict dictionary") end
    if lfs.attributes(target) then purge(staging); error("dictionary already installed") end
    assert(os.rename(staging, target))
end

local function downloadParts(item, dir, idx, done, report)
    local part = item.parts[idx]
    if not part then
        report("install", item.size, item.size, #item.parts, #item.parts)
        local target = installTarget(done.data_dir, item.id)
        _job = Task.run(function() assembleAndExtract(item, dir, target) end, {
            timeout = 300,
            on_done = function()
                _downloading, _job = false, nil
                if lfs.attributes(target, "mode") ~= "directory" then
                    done.callback(false, "dictionary installation failed")
                    return
                end
                purge(dir)
                done.callback(true)
            end,
            on_failed = function(err)
                _downloading, _job = false, nil
                done.callback(false, err)
            end,
        })
        return
    end
    if partComplete(dir, part) then
        report("part", idx, #item.parts, idx, #item.parts)
        downloadParts(item, dir, idx + 1, done, report)
        return
    end
    _job = Request.download({
        url = BASE_URL .. "/" .. part.file,
        method = "GET", timeout = 300, allow_redirects = true,
    }, dir .. "/" .. part.file, function(ok, err)
        if not ok or not partComplete(dir, part) then
            os.remove(dir .. "/" .. part.file)
            _downloading, _job = false, nil
            done.callback(false, err or "part size mismatch")
            return
        end
        report("part", idx, #item.parts, idx, #item.parts)
        downloadParts(item, dir, idx + 1, done, report)
    end)
end

--- 分片下载、校验、解压并原子安装字典。
---@param item table
---@param data_dir string
---@param cb fun(ok: boolean, err: any)
---@param on_progress fun(stage: string, done: number, total: number, idx: number, count: number)|nil
function Manager.install(item, data_dir, cb, on_progress)
    cb = cb or function() end
    local checked, err = Manager.validateManifest({ dictionaries = { item } })
    if not checked then cb(false, err); return end
    if _downloading then cb(false, "already downloading"); return end
    if Manager.isInstalled(data_dir, item.id) then cb(false, "dictionary already installed"); return end
    Paths.ensureSettings()
    local util_ok, make_err = require("util").makePath(data_dir)
    if not util_ok then cb(false, make_err); return end
    local dir = tmpDir(item.id)
    local dir_ok, dir_err = require("util").makePath(dir)
    if not dir_ok then cb(false, dir_err); return end
    _downloading = true
    local report = on_progress or function() end
    downloadParts(item, dir, 1, { data_dir = data_dir, callback = cb }, report)
end

--- 当前是否有下载/安装任务在跑。
---@return boolean
function Manager.downloading()
    return _downloading
end

--- 取消进行中的下载或安装任务。
function Manager.cancel()
    if _job then
        if _job.abort then _job.abort() elseif _job.cancel then _job.cancel() end
    end
    _job, _downloading = nil, false
end

local function scanIfos(path, out)
    out = out or {}
    local ok, iter, dir_obj = pcall(lfs.dir, path)
    if not ok then return out end
    for name in iter, dir_obj do
        if name ~= "." and name ~= ".." and name ~= "res" then
            local full = path .. "/" .. name
            local mode = lfs.attributes(full, "mode")
            if mode == "directory" then scanIfos(full, out)
            elseif mode == "file" and name:lower():match("%.ifo$") then out[#out + 1] = full end
        end
    end
    return out
end

--- 扫描 data_dir 下全部 .ifo 路径。
---@param data_dir string
---@return string[]
function Manager.installed(data_dir)
    return scanIfos(data_dir)
end

--- 重建 KOReader 的模块级 .ifo 缓存。ReaderDictionary 没有公开刷新 API；
--- 这里按其原生 downloadDictionary 的做法重置 init 捕获的 available_ifos。
---@param dictionary table
function Manager.refresh(dictionary)
    if not dictionary or type(dictionary.init) ~= "function" then return end
    for index = 1, 32 do
        local name = debug.getupvalue(dictionary.init, index)
        if not name then break end
        if name == "available_ifos" then
            debug.setupvalue(dictionary.init, index, false)
            break
        end
    end
    dictionary:init()
end

--- 启用指定 .ifo，其余字典标记禁用。
---@param dictionary table
---@param ifo_path string
function Manager.activate(dictionary, ifo_path)
    dictionary.dicts_disabled = dictionary.dicts_disabled or {}
    for _, path in ipairs(scanIfos(dictionary.data_dir)) do dictionary.dicts_disabled[path] = true end
    dictionary.dicts_disabled[ifo_path] = nil
    if G_reader_settings then G_reader_settings:saveSetting("dicts_disabled", dictionary.dicts_disabled) end
    if dictionary.updateSdcvDictNamesOptions then dictionary:updateSdcvDictNamesOptions() end
end

--- 删除本插件安装的字典（仅 book-<id>）；用户自装词典拒绝删除。
---@param dictionary table
---@param id string
---@return boolean, string|nil
function Manager.remove(dictionary, id)
    if not dictionary or type(dictionary.data_dir) ~= "string" or not safeId(id) then
        return false, "invalid dictionary"
    end
    local target = installTarget(dictionary.data_dir, id)
    if lfs.attributes(target, "mode") ~= "directory" then return false, "dictionary not installed" end
    local removed, remove_err = purge(target)
    if not removed and lfs.attributes(target) then return false, remove_err or "delete failed" end
    for path in pairs(dictionary.dicts_disabled or {}) do
        if path:sub(1, #target + 1) == target .. "/" then dictionary.dicts_disabled[path] = nil end
    end
    if G_reader_settings then G_reader_settings:saveSetting("dicts_disabled", dictionary.dicts_disabled or {}) end
    Manager.refresh(dictionary)
    return true
end

return Manager
