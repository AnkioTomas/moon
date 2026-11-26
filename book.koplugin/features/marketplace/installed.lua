--[[--
本机已安装插件扫描与市场安装记录：
  - 扫描月读同级 `*.koplugin` 目录，按 (mtime, size) 缓存 `_meta.lua` 静态解析结果；
  - `marketplace_installed` 表（book.sqlite3）记录市场安装身份与兜底版本号；
  - 「已安装」页只列出能与市场目录或安装记录核对的插件，排除月读核心（book.koplugin）。

@module koplugin.book.features.marketplace.installed
--]]

local lfs = require("libs/libkoreader-lfs")
local DB = require("utils.db")
local Meta = require("features.marketplace.meta")

local Installed = {}

Installed.RESERVED_DIRS = { ["book.koplugin"] = true }

DB.schema("marketplace_installed", function()
    return DB.exec([[
CREATE TABLE IF NOT EXISTS marketplace_installed (
  name TEXT PRIMARY KEY,
  uid TEXT NOT NULL DEFAULT '',
  type TEXT NOT NULL DEFAULT '',
  host TEXT NOT NULL DEFAULT '',
  owner TEXT NOT NULL DEFAULT '',
  repo TEXT NOT NULL DEFAULT '',
  title TEXT,
  kind TEXT,
  version TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_marketplace_installed_uid ON marketplace_installed(uid);
]]) ~= nil
end)

--- 插件目录名：单段、以 .koplugin 结尾，不得是月读核心。
---@param value any
---@return boolean
function Installed.isPluginDir(value)
    if type(value) ~= "string" then return false end
    if value:find("[/\\]") or value:find("%.%.") or value:find("%z") then return false end
    if not value:match("^[%w][%w._-]*%.koplugin$") then return false end
    return not Installed.RESERVED_DIRS[value]
end

---@param plugin_root string|nil
---@return string|nil
function Installed.parent(plugin_root)
    if type(plugin_root) ~= "string" or plugin_root == "" then return nil end
    local parent = plugin_root:match("^(.*)/[^/]+$")
    return (parent and parent ~= "") and parent or nil
end

---@param item table|nil
---@return string|nil
function Installed.repoKey(item)
    if type(item) ~= "table" then return nil end
    if type(item.type) ~= "string" or type(item.owner) ~= "string" or type(item.repo) ~= "string" then
        return nil
    end
    return table.concat({ item.type, tostring(item.host or ""), item.owner, item.repo }, "\0")
end

local meta_cache = {}

local function readMetaEntry(dir, name)
    local path = dir .. "/" .. Meta.FILENAME
    local attr = lfs.attributes(path)
    if not attr or attr.mode ~= "file" then
        meta_cache[path] = nil
        return nil
    end
    local cached = meta_cache[path]
    if cached and cached.mtime == attr.modification and cached.size == attr.size then
        return cached
    end
    local text = require("utils.fs").read(path)
    if not text then
        meta_cache[path] = nil
        return nil
    end
    local meta = select(1, Meta.parse(text))
    local entry = {
        mtime = attr.modification,
        size = attr.size,
        meta = meta,
        title = Meta.displayTitle(meta, name),
        description = Meta.displayDescription(meta),
        version = meta and meta.version or nil,
    }
    meta_cache[path] = entry
    return entry
end

--- 扫描本机插件目录。不包含月读核心的可更新市场动作，但仍可读出版本。
---@param plugin_root string
---@return table[]
function Installed.scan(plugin_root)
    local parent = Installed.parent(plugin_root)
    if not parent or lfs.attributes(parent, "mode") ~= "directory" then return {} end
    local out = {}
    for name in lfs.dir(parent) do
        if type(name) == "string" and name:sub(-9) == ".koplugin" and name ~= "." and name ~= ".." then
            local dir = parent .. "/" .. name
            if lfs.attributes(dir, "mode") == "directory" then
                local info = readMetaEntry(dir, name)
                out[#out + 1] = {
                    name = name,
                    path = dir,
                    reserved = Installed.RESERVED_DIRS[name] == true,
                    meta = info and info.meta or nil,
                    title = info and info.title or name,
                    description = info and info.description or nil,
                    version = info and info.version or nil,
                }
            end
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

---@param plugin_root string
---@return table<string, table>
function Installed.index(plugin_root)
    local map = {}
    for _idx, item in ipairs(Installed.scan(plugin_root)) do map[item.name] = item end
    return map
end

local function dirFromAsset(asset_name)
    if type(asset_name) ~= "string" then return nil end
    local dir = asset_name:match("^([%w][%w._-]*%.koplugin)")
    return Installed.isPluginDir(dir) and dir or nil
end

--- 推测目录条目对应的本机插件目录名（仅用于与本机已有目录匹配；实际安装以 zip 内顶层目录为准）。
---@param item table|nil
---@return string|nil
function Installed.pluginDir(item)
    if type(item) ~= "table" then return nil end
    local meta = type(item.meta) == "table" and item.meta or {}
    if Installed.isPluginDir(meta.plugin) then return meta.plugin end
    if Installed.isPluginDir(meta.name) then return meta.name end
    if type(meta.name) == "string" and Installed.isPluginDir(meta.name .. ".koplugin") then
        return meta.name .. ".koplugin"
    end
    local from_asset = dirFromAsset(item.release_asset)
        or (type(item.release_assets) == "table" and #item.release_assets == 1 and dirFromAsset(item.release_assets[1].name))
    if from_asset then return from_asset end
    if Installed.isPluginDir(item.repo) then return item.repo end
    if type(item.repo) == "string" and Installed.isPluginDir(item.repo .. ".koplugin") then
        return item.repo .. ".koplugin"
    end
    return nil
end

local record_index

local function nonEmpty(v)
    return (type(v) == "string" and v ~= "") and v or nil
end

local function loadRecordIndex()
    if record_index then return record_index end
    local result, nrows = DB.query(
        "SELECT name, uid, type, host, owner, repo, title, kind, version FROM marketplace_installed ORDER BY name ASC;"
    )
    local list, by_name, by_uid, by_repo = {}, {}, {}, {}
    for i = 1, result and nrows or 0 do
        local rec = {
            name = result[1][i],
            uid = nonEmpty(result[2][i]),
            type = nonEmpty(result[3][i]),
            host = nonEmpty(result[4][i]),
            owner = nonEmpty(result[5][i]),
            repo = nonEmpty(result[6][i]),
            title = result[7][i],
            kind = result[8][i],
            version = nonEmpty(result[9][i]),
        }
        list[i] = rec
        by_name[rec.name] = rec
        if rec.uid and not by_uid[rec.uid] then by_uid[rec.uid] = rec end
        local rk = Installed.repoKey(rec)
        if rk and not by_repo[rk] then by_repo[rk] = rec end
    end
    record_index = { list = list, by_name = by_name, by_uid = by_uid, by_repo = by_repo }
    return record_index
end

function Installed.clearRecords()
    DB.exec("DELETE FROM marketplace_installed;")
    record_index = nil
end

--- 本地 _meta.lua 缺失 version 时，用安装记录里的版本号兜底（不改原扫描表）。
local function withFallbackVersion(loc, record)
    if not loc or nonEmpty(loc.version) or not record or not nonEmpty(record.version) then
        return loc
    end
    local copy = {}
    for k, v in pairs(loc) do copy[k] = v end
    copy.version = record.version
    return copy
end

--- 安装成功后记下实际安装的插件目录名、市场身份与版本号（_meta.lua 无 version 时兜底比对更新）。
---@param plugin table
---@param name string
---@param version string|nil
---@return boolean|nil, string|nil
function Installed.remember(plugin, name, version)
    if type(plugin) ~= "table" or not Installed.isPluginDir(name) then
        return nil, Installed.RESERVED_DIRS[name] and "reserved" or "plugin"
    end
    local uid = nonEmpty(plugin.uid)
    local has_repo = type(plugin.type) == "string" and type(plugin.host) == "string"
        and type(plugin.owner) == "string" and type(plugin.repo) == "string"
    if not uid and not has_repo then return nil, "plugin" end
    local ok = DB.exec([[
        INSERT INTO marketplace_installed (name, uid, type, host, owner, repo, title, kind, version)
        VALUES (?,?,?,?,?,?,?,?,?)
        ON CONFLICT(name) DO UPDATE SET
          uid=excluded.uid, type=excluded.type, host=excluded.host,
          owner=excluded.owner, repo=excluded.repo, title=excluded.title,
          kind=excluded.kind, version=excluded.version;
    ]], name, uid or "", plugin.type or "", plugin.host or "",
        plugin.owner or "", plugin.repo or "", plugin.title, plugin.kind,
        -- catalog 顶层 require 了本模块，这里延迟加载。
        nonEmpty(version) or require("features.marketplace.catalog").catalogVersion(plugin) or "")
    if not ok then return nil, "write" end
    record_index = nil
    return true
end

local function addIn(col, values, clauses, args)
    if #values == 0 then return end
    local ph = {}
    for i = 1, #values do
        ph[i] = "?"
        args[#args + 1] = values[i]
    end
    clauses[#clauses + 1] = col .. " IN (" .. table.concat(ph, ",") .. ")"
end

--- 只查 SQLite 中与本机目录或安装记录相交的目录条目，避免为「已安装 / 更新」解码整库。
local function matchCatalogInDB(locals, by_record)
    local uids, repo_keys, dirs, seen_u, seen_r = {}, {}, {}, {}, {}
    for _idx, lp in ipairs(locals) do
        if not lp.reserved then
            dirs[#dirs + 1] = lp.name
            local rec = by_record[lp.name]
            if rec then
                if rec.uid and not seen_u[rec.uid] then seen_u[rec.uid] = true; uids[#uids + 1] = rec.uid end
                local rk = Installed.repoKey(rec)
                if rk and not seen_r[rk] then seen_r[rk] = true; repo_keys[#repo_keys + 1] = rk end
            end
        end
    end
    local clauses, args = {}, {}
    addIn("uid", uids, clauses, args)
    addIn("repo_key", repo_keys, clauses, args)
    addIn("plugin_dir", dirs, clauses, args)
    if #clauses == 0 then return {} end
    local result, nrows = DB.query(
        "SELECT payload FROM marketplace_plugins WHERE " .. table.concat(clauses, " OR ") .. " ORDER BY seq ASC;",
        unpack(args)
    )
    local out = {}
    for i = 1, result and nrows or 0 do
        local ok, item = pcall(require("json").decode, result[1][i])
        if ok and type(item) == "table" then out[#out + 1] = item end
    end
    return out
end

--- 市场支持且身份可核对的已安装插件。排除月读本体和未知本地插件。
---@param plugin_root string
---@param catalog_plugins table[]|nil 省略时直查 SQLite 相交行
---@param locals table[]|nil 已有扫描结果时复用
---@return table[]
function Installed.supported(plugin_root, catalog_plugins, locals)
    locals = locals or Installed.scan(plugin_root)
    if #locals == 0 then return {} end

    local rec_idx = loadRecordIndex()
    if catalog_plugins == nil then
        catalog_plugins = matchCatalogInDB(locals, rec_idx.by_name)
    end

    local by_uid, by_repo, by_dir = {}, {}, {}
    for _idx, item in ipairs(catalog_plugins or {}) do
        if type(item) == "table" then
            if nonEmpty(item.uid) then by_uid[item.uid] = item end
            local rk = Installed.repoKey(item)
            if rk and not by_repo[rk] then by_repo[rk] = item end
            local dir = Installed.pluginDir(item)
            if dir and not by_dir[dir] then by_dir[dir] = item end
        end
    end

    local out, local_by_name = {}, {}
    for _idx, lp in ipairs(locals) do
        if not lp.reserved then
            local_by_name[lp.name] = lp
            local rec = rec_idx.by_name[lp.name]
            local resolved = withFallbackVersion(lp, rec)
            local rk = rec and Installed.repoKey(rec)
            local cat_item = (rec and rec.uid and by_uid[rec.uid])
                or (rk and by_repo[rk])
                or by_dir[lp.name]
            if cat_item then
                out[#out + 1] = { local_plugin = resolved, plugin = cat_item }
            elseif rec then
                out[#out + 1] = {
                    local_plugin = resolved,
                    plugin = {
                        uid = rec.uid, type = rec.type, host = rec.host,
                        owner = rec.owner, repo = rec.repo,
                        title = rec.title or resolved.title, kind = rec.kind,
                        meta = resolved.meta, description = resolved.description,
                    },
                }
            end
        end
    end

    -- 目录已不在时丢掉对应记录，避免空壳身份残留。
    local removed = {}
    for _idx, rec in ipairs(rec_idx.list) do
        if not local_by_name[rec.name] then removed[#removed + 1] = rec.name end
    end
    if #removed > 0 then
        DB.transaction(function()
            for _idx, name in ipairs(removed) do
                if not DB.exec("DELETE FROM marketplace_installed WHERE name = ?;", name) then return false end
            end
            return true
        end)
        record_index = nil
    end
    return out
end

--- 返回某市场条目对应的本机已安装信息（优先查安装记录，再按推测目录名查）。
---@param plugin table|nil
---@param plugin_root string|nil
---@param locals table<string, table>|nil
---@return table|nil local_plugin
function Installed.findLocal(plugin, plugin_root, locals)
    if type(plugin) ~= "table" or not plugin_root then return nil end
    locals = locals or Installed.index(plugin_root)
    local idx = loadRecordIndex()
    local rec = (nonEmpty(plugin.uid) and idx.by_uid[plugin.uid]) or nil
    if not rec then
        local rk = Installed.repoKey(plugin)
        rec = rk and idx.by_repo[rk] or nil
    end
    if rec then
        local loc = locals[rec.name]
        if loc and not loc.reserved then return withFallbackVersion(loc, rec) end
    end
    local name = Installed.pluginDir(plugin)
    local loc = name and locals[name]
    if loc and not loc.reserved then return withFallbackVersion(loc, idx.by_name[name]) end
    return nil
end

--- KOReader `plugins_disabled` 的键：目录名去掉 `.koplugin`。
---@param dir_name string
---@return string|nil
function Installed.koName(dir_name)
    if not Installed.isPluginDir(dir_name) then return nil end
    return dir_name:sub(1, -10)
end

---@return table|nil
local function readerSettings()
    local settings = rawget(_G, "G_reader_settings")
    if type(settings) ~= "table" or type(settings.readSetting) ~= "function"
        or type(settings.saveSetting) ~= "function" then
        return nil
    end
    return settings
end

--- 插件是否已在 KOReader 里停用。停用后要重启才不再加载。
---@param dir_name string
---@return boolean
function Installed.isDisabled(dir_name)
    local key = Installed.koName(dir_name)
    local settings = readerSettings()
    if not key or not settings then return false end
    local list = settings:readSetting("plugins_disabled")
    return type(list) == "table" and list[key] == true
end

--- 写入 KOReader 的停用表。启用时删键，与插件管理器一致。
---@param dir_name string
---@param disabled boolean
---@return boolean|nil ok
---@return string|nil err
function Installed.setDisabled(dir_name, disabled)
    local key = Installed.koName(dir_name)
    if not key then return nil, "reserved" end
    local settings = readerSettings()
    if not settings then return nil, "settings" end
    local list = settings:readSetting("plugins_disabled")
    if type(list) ~= "table" then list = {} end
    list[key] = disabled and true or nil
    settings:saveSetting("plugins_disabled", list)
    if settings.flush then settings:flush() end
    return true
end

--- 删掉已安装的市场插件目录，并清安装记录与停用标记。不碰月读核心。
---@param plugin_root string
---@param dir_name string
---@return boolean|nil ok
---@return string|nil err
function Installed.remove(plugin_root, dir_name)
    if not Installed.isPluginDir(dir_name) then return nil, "reserved" end
    local parent = Installed.parent(plugin_root)
    if not parent then return nil, "plugin_root" end
    local path = parent .. "/" .. dir_name
    local attr = lfs.symlinkattributes(path)
    if not attr then return nil, "missing" end
    if attr.mode ~= "directory" then return nil, "reserved" end
    local ok = require("ffi/util").purgeDir(path)
    if not ok then return nil, "delete" end
    DB.exec("DELETE FROM marketplace_installed WHERE name = ?;", dir_name)
    record_index = nil
    meta_cache[path .. "/" .. Meta.FILENAME] = nil
    Installed.setDisabled(dir_name, false)
    return true
end

return Installed
