--[[--
X-Ray 本地存储：别名去重合并。

@module koplugin.book.xray.store
--]]

local JSON = require("json")
local Text = require("utils.text")
local XrayDB = require("utils.db.xray")

local Store = {}

--- 名字规范化（去空白 + 转小写），去重比较一律用它。
---@param name string|nil
---@return string
local function normName(name)
    return Text.trim(name):lower()
end

--- 解 JSON 列表；空串或解析失败一律当空表（库里的旧脏数据不该让阅读页崩）。
---@param raw string|nil
---@return table
local function decodeList(raw)
    if type(raw) ~= "string" or raw == "" then return {} end
    local ok, value = pcall(JSON.decode, raw)
    return ok and type(value) == "table" and value or {}
end

--- 编码成 JSON 串落库；编码失败退化为空列表。
---@param value any
---@return string
local function encode(value)
    local ok, payload = pcall(JSON.encode, value)
    return ok and payload or "[]"
end

--- 实体去重键：类型 + 规范名（同名不同类算两个实体）。
---@param kind string
---@param name string
---@return string
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

    --- 登记一个实体：占住去重键、记下出现顺序，并把名字与全部别名指向它。
    ---@param entity table
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
                if normName(name) ~= normName(cur.name) and not seen[normName(name)] then
                    cur.aliases[#cur.aliases + 1] = name
                    seen[normName(name)] = true
                end
                for _, a in ipairs(aliases) do
                    if not seen[normName(a)] then
                        cur.aliases[#cur.aliases + 1] = a
                        seen[normName(a)] = true
                    end
                end
                for k, v in pairs(payload) do
                    if type(v) == "string" and Text.trim(v) ~= "" then
                        cur.payload[k] = Text.trim(v)
                    elseif v ~= nil and cur.payload[k] == nil then
                        cur.payload[k] = v
                    end
                end
                alias_to_key[normName(cur.name)] = hit
                for _, a in ipairs(cur.aliases or {}) do alias_to_key[normName(a)] = hit end
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

--- 已有实体快照，供 AI prompt 引用（name 为数据库主键）。
---@param identity BookIdentity
---@return table
function Store.promptSnapshot(identity)
    local snapshot = { characters = {}, locations = {}, terms = {} }
    for _, entity in ipairs(Store.loadEntities(identity)) do
        local payload = entity.payload or {}
        local item = {
            name = entity.name,
            aliases = entity.aliases or {},
        }
        if entity.kind == "character" then
            item.role = payload.role or ""
            item.description = payload.description or ""
            snapshot.characters[#snapshot.characters + 1] = item
        elseif entity.kind == "location" then
            item.description = payload.description or ""
            snapshot.locations[#snapshot.locations + 1] = item
        else
            item.description = payload.description or ""
            snapshot.terms[#snapshot.terms + 1] = item
        end
    end
    return snapshot
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

--- 全量替换一本书的 X-Ray 实体。
---@param identity BookIdentity
---@param entities table[]
---@return boolean
function Store.replaceEntities(identity, entities)
    if not XrayDB.deleteAllForBook(identity.source_id, identity.stable_id) then
        return false
    end
    return Store.saveEntities(identity, entities)
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

return Store
