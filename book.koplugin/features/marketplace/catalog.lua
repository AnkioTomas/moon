--[[--
插件市场目录：从 moon-store.ankio.net 刷新插件列表与分类，直接存 SQLite（book.sqlite3）供离线浏览、
检索、按页懒加载与更新比对。刷新失败时保留库中旧目录，不清空已有数据。

@module koplugin.book.features.marketplace.catalog
--]]

local DB = require("utils.db")
local Client = require("features.marketplace.client")
local Meta = require("features.marketplace.meta")
local Installed = require("features.marketplace.installed")

local Catalog = {}

--- 后台自动刷新周期：6 小时。
Catalog.AUTO_REFRESH_INTERVAL = 6 * 3600

local state = {
    gen = 0,
    job = nil,
    refreshing = false,
    silent = false,
    last_error = nil,
}

DB.schema("marketplace_catalog", function()
    if not DB.exec([[
CREATE TABLE IF NOT EXISTS marketplace_plugins (
  uid TEXT PRIMARY KEY,
  seq INTEGER NOT NULL,
  updated_at INTEGER NOT NULL DEFAULT 0,
  category TEXT NOT NULL DEFAULT '',
  category_name TEXT NOT NULL DEFAULT '',
  kinds TEXT NOT NULL DEFAULT '',
  plugin_dir TEXT NOT NULL DEFAULT '',
  repo_key TEXT NOT NULL DEFAULT '',
  has_sub INTEGER NOT NULL DEFAULT 0,
  search_text TEXT NOT NULL DEFAULT '',
  payload TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_marketplace_plugins_dir ON marketplace_plugins(plugin_dir);
CREATE INDEX IF NOT EXISTS idx_marketplace_plugins_repo ON marketplace_plugins(repo_key);
CREATE TABLE IF NOT EXISTS marketplace_categories (
  code TEXT PRIMARY KEY,
  seq INTEGER NOT NULL,
  name TEXT NOT NULL,
  hint TEXT
);
CREATE TABLE IF NOT EXISTS marketplace_meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
]]) then return false end
    local cols, nrows = DB.query("PRAGMA table_info(marketplace_plugins);")
    local has_updated = false
    for i = 1, cols and nrows or 0 do
        if cols[2][i] == "updated_at" then has_updated = true; break end
    end
    if not has_updated and not DB.exec("ALTER TABLE marketplace_plugins ADD COLUMN updated_at INTEGER NOT NULL DEFAULT 0;") then
        return false
    end
    return DB.exec([[
CREATE INDEX IF NOT EXISTS idx_marketplace_plugins_updated ON marketplace_plugins(updated_at DESC, seq ASC);
CREATE INDEX IF NOT EXISTS idx_marketplace_plugins_cat_updated ON marketplace_plugins(category, updated_at DESC, seq ASC);
]]) ~= nil
end)

-- 只折 ASCII 大小写，避免当前 locale 下 string.lower 改写 UTF-8 中文字节。
local LOWER_MAP = {}
for b = 65, 90 do LOWER_MAP[string.char(b)] = string.char(b + 32) end

local function lower(text)
    if type(text) ~= "string" or text == "" then return "" end
    return (text:gsub("[A-Z]", LOWER_MAP))
end

local function normalizeQuery(query)
    if type(query) ~= "string" or query == "" then return "" end
    return lower((query:gsub("^%s+", ""):gsub("%s+$", "")))
end

local function decodePayload(text)
    if type(text) ~= "string" or text == "" then return nil end
    local ok, data = pcall(require("json").decode, text)
    return (ok and type(data) == "table") and data or nil
end

--- 解析语义化版本：支持两段（X.Y）或三段（X.Y.Z），可选 -prerelease 与 +build，排除 4 位年份日期型。
local function parseVersion(value)
    if type(value) ~= "string" or value == "" or value:match("^%d%d%d%d%.") then return nil end
    local core = value:match("^([^+]+)")
    if not core then return nil end
    local nums, pre = core:match("^(%d+%.%d+%.?%d*)%-([%w%.%-]+)$")
    nums = nums or core
    local a, b, c = nums:match("^(%d+)%.(%d+)%.(%d+)$")
    if not a then
        a, b = nums:match("^(%d+)%.(%d+)$")
        c = "0"
    end
    if not a then return nil end
    return tonumber(a), tonumber(b), tonumber(c), pre
end

local function comparePrerelease(a, b)
    if a == b then return 0 end
    if a == nil then return 1 end
    if b == nil then return -1 end
    local pa, pb = {}, {}
    for seg in a:gmatch("[^.]+") do pa[#pa + 1] = seg end
    for seg in b:gmatch("[^.]+") do pb[#pb + 1] = seg end
    for i = 1, math.min(#pa, #pb) do
        local sa, sb = pa[i], pb[i]
        if sa ~= sb then
            local na, nb = sa:match("^%d+$") and tonumber(sa), sb:match("^%d+$") and tonumber(sb)
            if na and nb then return na > nb and 1 or -1 end
            if na or nb then return na and -1 or 1 end
            return sa > sb and 1 or -1
        end
    end
    return #pa == #pb and 0 or (#pa > #pb and 1 or -1)
end

---@param tag any
---@return string
function Catalog.stripV(tag)
    return (tostring(tag or ""):gsub("^[vV]", ""))
end

--- 两边都能解析为版本且远端严格更新时才算「有更新」；未知版本不算更新。
---@param remote string|nil
---@param installed string|nil
---@return boolean
function Catalog.isNewer(remote, installed)
    if type(remote) ~= "string" or type(installed) ~= "string" then return false end
    local a1, a2, a3, ap = parseVersion(Catalog.stripV(remote))
    local b1, b2, b3, bp = parseVersion(Catalog.stripV(installed))
    if not a1 or not b1 then return false end
    if a1 ~= b1 then return a1 > b1 end
    if a2 ~= b2 then return a2 > b2 end
    if a3 ~= b3 then return a3 > b3 end
    return comparePrerelease(ap, bp) == 1
end

---@param item table|nil
---@return string|nil
function Catalog.displayTitle(item)
    if type(item) ~= "table" then return nil end
    if type(item.title) == "string" and item.title ~= "" then return item.title end
    local from_meta = Meta.displayTitle(item.meta)
    return (type(from_meta) == "string" and from_meta ~= "") and from_meta or item.repo
end

---@param item table|nil
---@return string|nil
function Catalog.displayDescription(item)
    if type(item) ~= "table" then return nil end
    if type(item.summary) == "string" and item.summary ~= "" then return item.summary end
    if type(item.description) == "string" and item.description ~= "" then return item.description end
    return Meta.displayDescription(item.meta)
end

---@param item table|nil
---@return string|nil
function Catalog.catalogVersion(item)
    if type(item) ~= "table" then return nil end
    if type(item.version) == "string" and item.version ~= "" then return item.version end
    if item.meta and type(item.meta.version) == "string" and item.meta.version ~= "" then
        return item.meta.version
    end
    if type(item.release_tag) == "string" and item.release_tag ~= "" then
        return Catalog.stripV(item.release_tag)
    end
    return nil
end

local function buildKinds(item)
    local out, seen = {}, {}
    local function add(k)
        if type(k) == "string" and k ~= "" then
            local lk = lower(k)
            if not seen[lk] then seen[lk] = true; out[#out + 1] = lk end
        end
    end
    add(item.kind)
    if type(item.kinds) == "table" then
        for _idx, k in ipairs(item.kinds) do add(k) end
    end
    return #out > 0 and ("\0" .. table.concat(out, "\0") .. "\0") or ""
end

local function buildSearchText(item)
    local parts = {}
    local function add(v)
        if type(v) == "string" and v ~= "" then parts[#parts + 1] = lower(v) end
    end
    add(item.title); add(item.summary); add(item.description)
    add(item.repo); add(item.owner); add(item.category_name)
    for _idx, tag in ipairs(type(item.tags) == "table" and item.tags or {}) do add(tag) end
    for _idx, topic in ipairs(type(item.topics) == "table" and item.topics or {}) do add(topic) end
    local meta = item.meta
    if type(meta) == "table" then
        add(meta.name); add(meta.fullname); add(meta.title); add(meta.description)
    end
    return table.concat(parts, "\0")
end

local function pluginColumns(item)
    local desc = Catalog.displayDescription(item)
    return tonumber(item.updated_at) or 0,
        lower(item.category),
        type(item.category_name) == "string" and item.category_name or "",
        buildKinds(item),
        Installed.pluginDir(item) or "",
        Installed.repoKey(item) or "",
        (type(desc) == "string" and desc ~= "") and 1 or 0,
        buildSearchText(item),
        require("json").encode(item)
end

local function buildFilter(query, category, kind)
    local q, cat, want = normalizeQuery(query), lower(category), lower(kind)
    local clauses, args = {}, {}
    if cat ~= "" then clauses[#clauses + 1] = "category = ?"; args[#args + 1] = cat end
    if want ~= "" then clauses[#clauses + 1] = "instr(kinds, ?) > 0"; args[#args + 1] = "\0" .. want .. "\0" end
    if q ~= "" then clauses[#clauses + 1] = "instr(search_text, ?) > 0"; args[#args + 1] = q end
    return #clauses > 0 and (" WHERE " .. table.concat(clauses, " AND ")) or "", args
end

function Catalog.saveCache(data)
    data = data or {}
    local updated_at = tonumber(data.updated_at) or os.time()
    local ok = DB.transaction(function()
        if not DB.exec("DELETE FROM marketplace_plugins;") then return false end
        if not DB.exec("DELETE FROM marketplace_categories;") then return false end
        local cseq = 0
        for _idx, item in ipairs(data.categories or {}) do
            if type(item) == "table" and type(item.code) == "string" and item.code ~= "" then
                cseq = cseq + 1
                local name = type(item.name) == "string" and item.name ~= "" and item.name or item.code
                local hint = type(item.hint) == "string" and item.hint or nil
                if not DB.exec(
                    "INSERT OR REPLACE INTO marketplace_categories (code, seq, name, hint) VALUES (?,?,?,?);",
                    item.code, cseq, name, hint
                ) then return false end
            end
        end
        local pseq = 0
        for _idx, item in ipairs(data.plugins or {}) do
            if type(item) == "table" and type(item.uid) == "string" and item.uid ~= "" then
                pseq = pseq + 1
                local upd, cat, cat_name, kinds, pdir, rkey, has_sub, search, payload = pluginColumns(item)
                if not DB.exec([[
                    INSERT OR REPLACE INTO marketplace_plugins
                      (uid, seq, updated_at, category, category_name, kinds, plugin_dir, repo_key, has_sub, search_text, payload)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?);
                ]], item.uid, pseq, upd, cat, cat_name, kinds, pdir, rkey, has_sub, search, payload) then
                    return false
                end
            end
        end
        return DB.exec(
            "INSERT OR REPLACE INTO marketplace_meta (key, value) VALUES ('updated_at', ?);",
            tostring(updated_at)
        ) ~= nil
    end)
    if not ok then return nil, "write" end
    return true
end

function Catalog.clear()
    DB.transaction(function()
        return DB.exec("DELETE FROM marketplace_plugins;") ~= nil
            and DB.exec("DELETE FROM marketplace_categories;") ~= nil
            and DB.exec("DELETE FROM marketplace_meta;") ~= nil
    end)
    state.last_error = nil
end

function Catalog.cancel()
    state.gen = state.gen + 1
    if state.job and state.job.cancel then state.job.cancel() end
    state.job = nil
    state.refreshing = false
    state.silent = false
end

--- 按筛选条件统计插件总数（直走 SQLite COUNT，不解码 JSON）。
---@param query string|nil
---@param category string|nil
---@param kind string|nil
---@return integer
function Catalog.count(query, category, kind)
    local where, args = buildFilter(query, category, kind)
    return tonumber(DB.rowexec("SELECT COUNT(*) FROM marketplace_plugins" .. where .. ";", unpack(args))) or 0
end

--- 返回筛选后的轻量索引 `{ uid, has_sub }[]`（不解码 JSON），供列表页按页懒加载单条详情。
---@param query string|nil
---@param category string|nil
---@param kind string|nil
---@return { uid: string, has_sub: boolean }[]
function Catalog.listIndex(query, category, kind)
    local where, args = buildFilter(query, category, kind)
    local result, nrows = DB.query(
        "SELECT uid, has_sub FROM marketplace_plugins" .. where .. " ORDER BY updated_at DESC, seq ASC;",
        unpack(args)
    )
    local out = {}
    for i = 1, result and nrows or 0 do
        out[i] = { uid = result[1][i], has_sub = tonumber(result[2][i]) == 1 }
    end
    return out
end

--- 按 uid 取单条插件对象（只解码这一行）。
---@param uid string
---@return table|nil
function Catalog.get(uid)
    if type(uid) ~= "string" or uid == "" then return nil end
    return decodePayload(DB.rowexec("SELECT payload FROM marketplace_plugins WHERE uid = ?;", uid))
end

--- 按安装目录名取插件。目录名在刷新时由 Installed.pluginDir 写入。
---@param dir string
---@return table|nil
function Catalog.byPluginDir(dir)
    if type(dir) ~= "string" or dir == "" then return nil end
    return decodePayload(DB.rowexec("SELECT payload FROM marketplace_plugins WHERE plugin_dir = ?;", dir))
end

--- 按筛选条件列出完整插件对象（全走 SQLite，按更新时间倒序）。
---@param query string|nil
---@param category string|nil
---@param kind string|nil
---@return table[]
function Catalog.filter(query, category, kind)
    local where, args = buildFilter(query, category, kind)
    local result, nrows = DB.query(
        "SELECT payload FROM marketplace_plugins" .. where .. " ORDER BY updated_at DESC, seq ASC;",
        unpack(args)
    )
    local out = {}
    for i = 1, result and nrows or 0 do
        local item = decodePayload(result[1][i])
        if item then out[#out + 1] = item end
    end
    return out
end

---@return table[]
function Catalog.plugins()
    return Catalog.filter()
end

---@return table[]
function Catalog.categories()
    local result, nrows = DB.query("SELECT code, name, hint FROM marketplace_categories ORDER BY seq ASC;")
    if result and nrows > 0 then
        local out = {}
        for i = 1, nrows do
            out[i] = { code = result[1][i], name = result[2][i], hint = result[3][i] }
        end
        return out
    end
    local agg, an = DB.query([[
        SELECT category, MAX(category_name) FROM marketplace_plugins
        WHERE category <> '' GROUP BY category ORDER BY category ASC;
    ]])
    local out = {}
    for i = 1, agg and an or 0 do
        local code, name = agg[1][i], agg[2][i]
        out[i] = { code = code, name = (type(name) == "string" and name ~= "") and name or code }
    end
    return out
end

---@param code string|nil
---@return string|nil
function Catalog.categoryName(code)
    if type(code) ~= "string" or code == "" then return nil end
    local name = DB.rowexec("SELECT name FROM marketplace_categories WHERE code = ?;", code)
    if type(name) == "string" and name ~= "" then return name end
    local fallback = DB.rowexec(
        "SELECT category_name FROM marketplace_plugins WHERE category = ? AND category_name <> '' LIMIT 1;",
        lower(code)
    )
    return (type(fallback) == "string" and fallback ~= "") and fallback or code
end

function Catalog.lastError() return state.last_error end
function Catalog.isRefreshing() return state.refreshing end
function Catalog.isManualRefreshing() return state.refreshing and not state.silent end

function Catalog.updatedAt()
    return tonumber(DB.rowexec("SELECT value FROM marketplace_meta WHERE key = 'updated_at';")) or 0
end

--- 目录是否已过期（距上次成功刷新超过 AUTO_REFRESH_INTERVAL，或从未刷新）。
---@param now integer|nil
---@return boolean
function Catalog.isStale(now)
    local updated = Catalog.updatedAt()
    return updated <= 0 or (now or os.time()) - updated >= Catalog.AUTO_REFRESH_INTERVAL
end

local function sameValue(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do if not sameValue(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

--- 详情接口拉回更新后的字段时单行合并回 SQLite；字段无变化时不写库。
---@param detail table|nil
---@return boolean updated
function Catalog.mergeDetail(detail)
    if type(detail) ~= "table" or type(detail.uid) ~= "string" or detail.uid == "" then return false end
    local item = Catalog.get(detail.uid)
    if not item then return false end
    local changed = false
    for k, v in pairs(detail) do
        if k ~= "readme" and not sameValue(item[k], v) then changed = true; break end
    end
    if not changed then return false end
    local merged = {}
    for k, v in pairs(item) do merged[k] = v end
    for k, v in pairs(detail) do if k ~= "readme" then merged[k] = v end end
    local upd, cat, cat_name, kinds, pdir, rkey, has_sub, search, payload = pluginColumns(merged)
    return DB.exec([[
        UPDATE marketplace_plugins
        SET updated_at=?, category=?, category_name=?, kinds=?, plugin_dir=?, repo_key=?, has_sub=?, search_text=?, payload=?
        WHERE uid=?;
    ]], upd, cat, cat_name, kinds, pdir, rkey, has_sub, search, payload, detail.uid) ~= nil
end

--- 刷新插件目录与分类。并发刷新会取消上一轮；失败保留库中旧数据。
--- opts.silent = true 时为后台静默刷新：失败不污染 last_error，也不阻止用户手动刷新接管。
---@param cb (fun(err: string|nil))|nil
---@param opts { on_progress?: fun(done: integer, total: integer), silent?: boolean }|nil
---@return table job
function Catalog.refresh(cb, opts)
    opts = opts or {}
    local silent = opts.silent == true
    Catalog.cancel()
    state.gen = state.gen + 1
    local gen = state.gen
    state.refreshing = true
    state.silent = silent
    if not silent then state.last_error = nil end

    local jobs = {}
    local handle = { cancel = function()
        if state.gen == gen then
            state.gen = state.gen + 1
            state.refreshing = false
            state.silent = false
            state.job = nil
        end
        for _idx, job in ipairs(jobs) do
            if job and job.cancel then job.cancel() end
        end
    end }
    state.job = handle

    local function finish(err)
        if gen ~= state.gen then return end
        state.refreshing = false
        state.silent = false
        state.job = nil
        if not err then
            state.last_error = nil
        elseif not silent then
            state.last_error = err
        end
        if cb then cb(err) end
    end

    local pending = 2
    local fetched_plugins, fetched_categories, first_err

    local function settle()
        if gen ~= state.gen then return end
        pending = pending - 1
        if pending > 0 then return end
        if not fetched_plugins then
            finish(first_err or "network")
            return
        end
        local ok, save_err = Catalog.saveCache({
            updated_at = os.time(),
            categories = fetched_categories or Catalog.categories(),
            plugins = fetched_plugins,
        })
        finish(not ok and (save_err or "write") or nil)
    end

    jobs[1] = Client.listCategories(function(items)
        if gen ~= state.gen then return end
        if type(items) == "table" then fetched_categories = items end
        settle()
    end)
    jobs[2] = Client.listPlugins(function(items, err)
        if gen ~= state.gen then return end
        if type(items) == "table" then fetched_plugins = items else first_err = err or "network" end
        settle()
    end, function(done, total)
        if gen ~= state.gen then return end
        if type(opts.on_progress) == "function" then opts.on_progress(done, total) end
    end)

    return handle
end

return Catalog
