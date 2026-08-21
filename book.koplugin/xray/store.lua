--[[--
X-Ray 本地存储：别名去重合并、时间线 TOC 对齐。

@module koplugin.book.xray.store
--]]

local JSON = require("json")
local Text = require("utils.text")
local XrayDB = require("utils.db.xray")

local Store = {}

local function normName(name)
    return Text.trim(name):lower()
end

local function decodeList(raw)
    if type(raw) ~= "string" or raw == "" then return {} end
    local ok, value = pcall(JSON.decode, raw)
    return ok and type(value) == "table" and value or {}
end

local function encode(value)
    local ok, payload = pcall(JSON.encode, value)
    return ok and payload or "[]"
end

local function entityKey(kind, name)
    return kind .. "\0" .. normName(name)
end

--- 把 AI 返回的实体列表合并进已有列表（按规范名 + 别名去重）。
---@param existing table[] 已解码实体 { kind, name, aliases, payload }
---@param incoming table[] AI 项（需带 kind）
---@return table[]
function Store.mergeEntities(existing, incoming)
    local by_key = {}
    local alias_to_key = {}
    local order = {}

    local function remember(entity)
        local key = entityKey(entity.kind, entity.name)
        by_key[key] = entity
        order[#order + 1] = key
        alias_to_key[normName(entity.name)] = key
        for _, alias in ipairs(entity.aliases or {}) do
            local n = normName(alias)
            if n ~= "" then alias_to_key[n] = key end
        end
    end

    for _, row in ipairs(existing or {}) do
        remember(row)
    end

    for _, item in ipairs(incoming or {}) do
        local kind = item.kind
        local name = Text.trim(item.name)
        if kind and name ~= "" then
            local aliases = {}
            for _, alias in ipairs(type(item.aliases) == "table" and item.aliases or {}) do
                alias = Text.trim(alias)
                if alias ~= "" and normName(alias) ~= normName(name) then
                    aliases[#aliases + 1] = alias
                end
            end
            local payload = item.payload or {}
            local hit = alias_to_key[normName(name)]
            if not hit then
                for _, alias in ipairs(aliases) do
                    hit = alias_to_key[normName(alias)]
                    if hit then break end
                end
            end
            if hit and by_key[hit] then
                local cur = by_key[hit]
                local seen = {}
                for _, a in ipairs(cur.aliases or {}) do seen[normName(a)] = true end
                for _, a in ipairs(aliases) do
                    if not seen[normName(a)] then
                        cur.aliases[#cur.aliases + 1] = a
                        seen[normName(a)] = true
                    end
                end
                if normName(name) ~= normName(cur.name) and #name > #cur.name then
                    cur.aliases[#cur.aliases + 1] = cur.name
                    cur.name = name
                end
                for k, v in pairs(payload) do
                    if type(v) == "string" and Text.trim(v) ~= "" then
                        cur.payload[k] = Text.trim(v)
                    elseif v ~= nil and cur.payload[k] == nil then
                        cur.payload[k] = v
                    end
                end
                alias_to_key[normName(name)] = hit
                for _, a in ipairs(aliases) do alias_to_key[normName(a)] = hit end
            else
                remember({
                    kind = kind,
                    name = name,
                    aliases = aliases,
                    payload = payload,
                })
            end
        end
    end

    local out = {}
    local seen_key = {}
    for _, key in ipairs(order) do
        if by_key[key] and not seen_key[key] then
            seen_key[key] = true
            out[#out + 1] = by_key[key]
        end
    end
    return out
end

--- TOC 项：{ title, page }；给 timeline 填 page/sort_idx。
---@param events table[] { chapter, event }
---@param toc table[]|nil
---@return table[]
function Store.alignTimeline(events, toc)
    local by_title = {}
    for i, entry in ipairs(toc or {}) do
        local title = Text.trim(entry.title or entry.chapter or "")
        if title ~= "" then
            by_title[normName(title)] = {
                page = tonumber(entry.page) or 0,
                sort_idx = i,
                title = title,
            }
        end
    end
    local out = {}
    for i, ev in ipairs(events or {}) do
        local chapter = Text.trim(ev.chapter)
        if chapter ~= "" then
            local hit = by_title[normName(chapter)]
            out[#out + 1] = {
                chapter = hit and hit.title or chapter,
                event = Text.trim(ev.event),
                page = hit and hit.page or tonumber(ev.page) or 0,
                sort_idx = hit and hit.sort_idx or i,
            }
        end
    end
    table.sort(out, function(a, b)
        if a.sort_idx ~= b.sort_idx then return a.sort_idx < b.sort_idx end
        return a.page < b.page
    end)
    return out
end

--- 读取已解码实体列表；kind 非空时过滤。
---@param identity BookIdentity
---@param kind string|nil
---@return table[]
function Store.loadEntities(identity, kind)
    local rows = XrayDB.listEntities(identity.source_id, identity.stable_id, kind)
    local out = {}
    for _, row in ipairs(rows) do
        out[#out + 1] = {
            kind = row.kind,
            name = row.name,
            aliases = decodeList(row.aliases_json),
            payload = decodeList(row.payload_json),
            updated_at = row.updated_at,
        }
    end
    return out
end

--- 批量落盘实体（aliases / payload 编码为 JSON）。
---@param identity BookIdentity
---@param entities table[]
---@return boolean
function Store.saveEntities(identity, entities)
    local now = os.time()
    for _, entity in ipairs(entities or {}) do
        if not XrayDB.upsertEntity(
            identity.source_id, identity.stable_id, entity.kind, entity.name,
            encode(entity.aliases or {}), encode(entity.payload or {}), now
        ) then
            return false
        end
    end
    return true
end

--- 读取时间线。
---@param identity BookIdentity
---@return table[]
function Store.loadTimeline(identity)
    return XrayDB.listTimeline(identity.source_id, identity.stable_id)
end

--- 批量落盘时间线。
---@param identity BookIdentity
---@param events table[]
---@return boolean
function Store.saveTimeline(identity, events)
    local now = os.time()
    for _, ev in ipairs(events or {}) do
        if not XrayDB.upsertTimeline(
            identity.source_id, identity.stable_id, ev.chapter, ev.event,
            ev.page, ev.sort_idx, now
        ) then
            return false
        end
    end
    return true
end

--- 读取 X-Ray 元数据。
---@param identity BookIdentity
---@return table|nil
function Store.loadMeta(identity)
    return XrayDB.getMeta(identity.source_id, identity.stable_id)
end

--- 写入上次拉取页与书类型。
---@param identity BookIdentity
---@param last_fetch_page integer
---@param book_type string|nil
---@return boolean
function Store.saveMeta(identity, last_fetch_page, book_type)
    return XrayDB.upsertMeta(identity.source_id, identity.stable_id,
        last_fetch_page, book_type)
end

return Store
