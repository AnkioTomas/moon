--[[--
插件详情与 README 获取与本地缓存。
经 moon-store.ankio.net `/api/v1/store/plugins/{uid}` 一次取回完整详情与 README，
按 uid 落盘独立小文件（cache/marketplace-readme/<md5>.json），按目录版本号失效，不常驻内存。

@module koplugin.book.features.marketplace.readme
--]]

local lfs = require("libs/libkoreader-lfs")
local Paths = require("utils.paths")
local Client = require("features.marketplace.client")
local Catalog = require("features.marketplace.catalog")

local Readme = {}

Readme.CACHE_DIR = "marketplace-readme"

local jobs = {}

---@return string
function Readme.cacheDir()
    return Paths.cacheDir() .. "/" .. Readme.CACHE_DIR
end

---@param plugin table|nil
---@return string|nil
function Readme.key(plugin)
    if type(plugin) ~= "table" then return nil end
    return (type(plugin.uid) == "string" and plugin.uid ~= "") and plugin.uid or nil
end

---@param key string
---@return string
local function entryPath(key)
    return Readme.cacheDir() .. "/" .. Paths.slugFor(key) .. ".json"
end

--- 清空磁盘上的全部 README 缓存文件。
function Readme.clearCache()
    local dir = Readme.cacheDir()
    if lfs.attributes(dir, "mode") == "directory" then
        for name in lfs.dir(dir) do
            if name ~= "." and name ~= ".." then os.remove(dir .. "/" .. name) end
        end
    end
end

function Readme.cancel()
    local active = jobs
    jobs = {}
    for job in pairs(active) do
        if job and job.cancel then job.cancel() end
    end
end

local function loadEntry(key)
    local file = io.open(entryPath(key), "rb")
    if not file then return nil end
    local text = file:read("*a")
    file:close()
    local ok, data = pcall(require("json").decode, text or "")
    return (ok and type(data) == "table") and data or nil
end

local function isFresh(entry, plugin)
    if type(entry) ~= "table" then return false end
    local want = Catalog.catalogVersion(plugin)
    if type(want) ~= "string" or want == "" then return true end
    local have = (type(entry.version) == "string" and entry.version ~= "" and entry.version)
        or Catalog.catalogVersion(entry.detail)
    if type(have) ~= "string" or have == "" then return false end
    return Catalog.stripV(have) == Catalog.stripV(want)
end

---@param plugin table|nil
---@return table|nil
function Readme.get(plugin)
    local key = Readme.key(plugin)
    if not key then return nil end
    local entry = loadEntry(key)
    return isFresh(entry, plugin) and entry or nil
end

local function store(key, detail, plugin)
    local readme = type(detail.readme) == "table" and detail.readme or {}
    local clean_detail = {}
    for k, v in pairs(detail) do
        if k ~= "readme" then clean_detail[k] = v end
    end
    local entry = {
        uid = key,
        version = Catalog.catalogVersion(clean_detail) or Catalog.catalogVersion(plugin) or "",
        name = type(readme.name) == "string" and readme.name or "",
        text = type(readme.text) == "string" and readme.text or "",
        detail = clean_detail,
        updated_at = os.time(),
    }
    Paths.ensureDir(Readme.cacheDir())
    local file = io.open(entryPath(key), "wb")
    if file then
        file:write(require("json").encode(entry))
        file:close()
    end
    return entry
end

--- 读取插件详情与 README。命中未过期缓存直接返回（除非 opts.force），失败时若磁盘有旧缓存则回落。
---@param plugin table
---@param cb fun(item: table|nil, err: string|nil)
---@param opts { force?: boolean }|nil
---@return table job
function Readme.fetch(plugin, cb, opts)
    opts = opts or {}
    local key = Readme.key(plugin)
    if not key then
        cb(nil, "missing")
        return { cancel = function() end }
    end
    local raw = loadEntry(key)
    if not opts.force and isFresh(raw, plugin) then
        cb(raw)
        return { cancel = function() end }
    end
    local cancelled, current, job = false, nil, nil
    job = {
        cancel = function()
            cancelled = true
            jobs[job] = nil
            if current and current.cancel then current.cancel() end
        end,
    }
    jobs[job] = true

    current = Client.getDetail(key, function(detail, err)
        jobs[job] = nil
        if cancelled then return end
        if type(detail) == "table" then
            Catalog.mergeDetail(detail)
            cb(store(key, detail, plugin), nil)
            return
        end
        if raw then cb(raw, nil) else cb(nil, err or "network") end
    end)
    return job
end

--- 当前在途请求数（测试用于校验完成/取消后无引用残留）。
---@return integer
function Readme.pendingCount()
    local n = 0
    for _job in pairs(jobs) do n = n + 1 end
    return n
end

return Readme
