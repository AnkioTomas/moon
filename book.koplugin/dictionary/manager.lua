--[[--
StarDict 词典管理：清单、分片下载校验、原子安装、切换与受控删除。

只有 `book-<id>` 目录归本插件所有；用户自行安装的词典只允许切换，不允许删除。

@module koplugin.book.dictionary.manager
--]]

local JSON = require("json")
local Request = require("http.request")
local Paths = require("utils.paths")
local Job = require("workers.job")
local lfs = require("libs/libkoreader-lfs")

local Manager = {}
local BASE_URL = "https://cdn.jsdelivr.net/gh/AnkioTomas/moon@main/assets/dict"
local _job
local _downloading = false

--- 校验字典 id：清单来自网络，id 会拼进目录名与分片文件名，
--- 只放行 `[%w_-]`，否则 `../` 之类能写到数据目录外。
---@param value any
---@return string|nil 合法时返回原值
local function safeId(value)
    return type(value) == "string" and value:match("^[%w_%-]+$") and value or nil
end

--- 是否为 sha256 十六进制串（64 位）。
---@param value any
---@return boolean
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
        local part_prefix = item.id .. ".part."
        for _, part in ipairs(item.parts) do
            if type(part) ~= "table" or type(part.file) ~= "string"
                or part.file:sub(1, #part_prefix) ~= part_prefix
                or part.file:sub(#part_prefix + 1):match("^%d%d%d$") == nil
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

--- 分片下载的临时目录（保留即为续传依据，安装成功后才清）。
---@param id string
---@return string
local function tmpDir(id)
    return Paths.root() .. "/dict-" .. id .. ".dl"
end

--- 递归删除但不跟随符号链接，避免受控目录里的链接把删除扩散到目录外。
---@param path string
---@return boolean|nil, string|nil
local function purge(path)
    local attr, attr_err = lfs.symlinkattributes(path)
    if not attr then
        return nil, attr_err
    end
    if attr.mode ~= "directory" then
        return os.remove(path)
    end
    local ok, iter, dir_obj = pcall(lfs.dir, path)
    if not ok then return nil, iter end
    for name in iter, dir_obj do
        if name ~= "." and name ~= ".." then
            local removed, remove_err = purge(path .. "/" .. name)
            if not removed then return nil, remove_err end
        end
    end
    return os.remove(path)
end

--- 分片是否已完整落盘：只比长度，sha256 留到拼接时统一校验（避免每次重启全量重算）。
---@param dir string 临时目录
---@param part table 清单里的分片项（file/size/sha256）
---@return boolean
local function partComplete(dir, part)
    local attr = lfs.attributes(dir .. "/" .. part.file)
    return attr and attr.mode == "file" and attr.size == tonumber(part.size)
end

--- 安装目录。`book-` 前缀是所有权标记：只有这个前缀的词典允许被本插件删除。
---@param data_dir string KOReader 词典根目录
---@param id string
---@return string
local function installTarget(data_dir, id)
    return data_dir .. "/book-" .. id
end

--- 是否已安装本插件管理的字典（book-<id> 目录）。
---@param data_dir string
---@param id string
---@return boolean
function Manager.isInstalled(data_dir, id)
    return safeId(id) ~= nil and lfs.symlinkattributes(installTarget(data_dir, id), "mode") == "directory"
end

--- 拼接分片 → 逐片与整包校验 sha256 → 解压到 `target .. ".part"` → 整目录 rename 到位。
--- 全程失败即 error（跑在 Job 子进程里，由 on_failed 接住）：
--- 解压到暂存目录再 rename 是为了原子性，中途失败不会留下半个词典被 KOReader 读到。
--- 归档内路径必须逐条查绝对路径与 `..`，否则能写到词典目录之外。
---@param item table 清单项（id/size/sha256/parts）
---@param dir string 分片所在临时目录
---@param target string 最终安装目录
local function assembleAndExtract(item, dir, target)
    local sha256 = require("ffi/sha2").sha256
    local archive = dir .. "/archive.part"
    local output = assert(io.open(archive, "wb"))
    local total = 0
    for _, part in ipairs(item.parts) do
        local part_path = dir .. "/" .. part.file
        local file = assert(io.open(part_path, "rb"))
        local data = file:read("*a")
        file:close()
        if #data ~= tonumber(part.size) or sha256(data) ~= part.sha256 then
            output:close()
            os.remove(part_path)
            error("part sha256 mismatch: " .. part.file)
        end
        assert(output:write(data))
        total = total + #data
    end
    assert(output:close())
    local archive_file = assert(io.open(archive, "rb"))
    local archive_data = assert(archive_file:read("*a"))
    archive_file:close()
    if total ~= tonumber(item.size) or sha256(archive_data) ~= item.sha256 then
        error("dictionary sha256 mismatch")
    end
    archive_data = nil

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
    local iterate_err = reader.err
    reader:close()
    if iterate_err then
        purge(staging)
        error(iterate_err)
    end
    if not has_ifo then purge(staging); error("archive contains no StarDict dictionary") end
    if lfs.symlinkattributes(target) then purge(staging); error("dictionary already installed") end
    assert(os.rename(staging, target))
end

--- 逐片下载（递归推进，串行；已完整的片直接跳过 = 续传），全部到位后转入解压安装。
--- 任一片失败即删除该片、清 `_downloading` 并回调失败，不重试。
---@param item table 清单项
---@param dir string 临时目录
---@param idx number 当前分片序号（从 1 起）
---@param done table `{ data_dir = string, callback = fun(ok: boolean, err: any) }`
---@param report fun(stage: string, done: number, total: number, idx: number, count: number) stage 为 "part"/"install"
local function downloadParts(item, dir, idx, done, report)
    local part = item.parts[idx]
    if not part then
        report("install", item.size, item.size, #item.parts, #item.parts)
        local target = installTarget(done.data_dir, item.id)
        _job = Job.run(function() assembleAndExtract(item, dir, target) end, {
            name = "dictionary.install",
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
    local dir_attr = lfs.symlinkattributes(dir)
    if dir_attr and dir_attr.mode ~= "directory" then
        cb(false, "invalid download directory")
        return
    end
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
        if _job.abort then _job:abort() elseif _job.cancel then _job:cancel() end
    end
    _job, _downloading = nil, false
end

--- 递归收集 `.ifo` 路径（StarDict 词典的标识文件）。跳过 `res`（词典自带资源目录，里面没有 .ifo）。
--- 目录不可读时静默返回已收集的结果：用户可能手工放了权限不对的目录，不该让整个词典列表崩掉。
---@param path string
---@param out string[]|nil 累积结果
---@return string[]
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
    if lfs.symlinkattributes(target, "mode") ~= "directory" then return false, "dictionary not installed" end
    local removed, remove_err = purge(target)
    if not removed and lfs.symlinkattributes(target) then return false, remove_err or "delete failed" end
    for path in pairs(dictionary.dicts_disabled or {}) do
        if path:sub(1, #target + 1) == target .. "/" then dictionary.dicts_disabled[path] = nil end
    end
    if G_reader_settings then G_reader_settings:saveSetting("dicts_disabled", dictionary.dicts_disabled or {}) end
    Manager.refresh(dictionary)
    return true
end

return Manager
