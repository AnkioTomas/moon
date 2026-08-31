--[[--
X-Ray 实体：别名去重合并与提示词快照。

@module koplugin.book.xray.store
--]]

local Text = require("utils.text")

local Store = {}
local detail_fields = { "role", "description", "gender", "occupation" }

--- 名字规范化（去空白 + 转小写），去重比较一律用它。
---@param name string|nil
---@return string
local function normName(name)
    return Text.trim(name):lower()
end

--- 实体去重键：类型 + 规范名（同名不同类算两个实体）。
---@param kind string
---@param name string
---@return string
local function entityKey(kind, name)
    return kind .. "\0" .. normName(name)
end

--- 把 AI 返回的实体列表合并进已有列表（按规范名 + 别名去重）。
---@param existing table[] 已解码实体 { kind, name, aliases, role, description, gender, occupation }
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
        alias_to_key[entityKey(entity.kind, entity.name)] = key
        for index, alias in ipairs(entity.aliases) do
            local n = normName(alias)
            if n ~= "" then alias_to_key[entityKey(entity.kind, n)] = key end
        end
    end

    for index, row in ipairs(existing) do
        remember(row)
    end

    for index, item in ipairs(incoming) do
        local kind = item.kind
        local name = Text.trim(item.name)
        if kind and name ~= "" then
            local aliases = {}
            for index, alias in ipairs(item.aliases) do
                alias = Text.trim(alias)
                if alias ~= "" and normName(alias) ~= normName(name) then
                    aliases[#aliases + 1] = alias
                end
            end
            local hit = alias_to_key[entityKey(kind, name)]
            if not hit then
                for index, alias in ipairs(aliases) do
                    hit = alias_to_key[entityKey(kind, alias)]
                    if hit then break end
                end
            end
            if hit and by_key[hit] then
                local cur = by_key[hit]
                local seen = {}
                for index, alias in ipairs(cur.aliases) do seen[normName(alias)] = true end
                if normName(name) ~= normName(cur.name) and not seen[normName(name)] then
                    cur.aliases[#cur.aliases + 1] = name
                    seen[normName(name)] = true
                end
                for index, alias in ipairs(aliases) do
                    if not seen[normName(alias)] then
                        cur.aliases[#cur.aliases + 1] = alias
                        seen[normName(alias)] = true
                    end
                end
                for index, field in ipairs(detail_fields) do
                    local value = Text.trim(item[field])
                    if value ~= "" then
                        cur[field] = value
                    end
                end
                alias_to_key[entityKey(cur.kind, cur.name)] = hit
                for index, alias in ipairs(cur.aliases) do
                    alias_to_key[entityKey(cur.kind, alias)] = hit
                end
            else
                remember({
                    kind = kind,
                    name = name,
                    aliases = aliases,
                    role = Text.trim(item.role),
                    description = Text.trim(item.description),
                    gender = Text.trim(item.gender),
                    occupation = Text.trim(item.occupation),
                })
            end
        end
    end

    local out = {}
    local seen_key = {}
    for index, key in ipairs(order) do
        if by_key[key] and not seen_key[key] then
            seen_key[key] = true
            out[#out + 1] = by_key[key]
        end
    end
    return out
end

--- 把已有实体整理成 AI prompt 所需的三类快照。
---@param entities table[]
---@return table
function Store.promptSnapshot(entities)
    local snapshot = { characters = {}, locations = {}, terms = {} }
    local buckets = {
        character = snapshot.characters,
        location = snapshot.locations,
        term = snapshot.terms,
    }
    for entity_index, entity in ipairs(entities) do
        local bucket = buckets[entity.kind]
        if bucket then
            local item = {
                name = entity.name,
                aliases = entity.aliases,
            }
            if entity.kind == "character" then
                item.role = entity.role or ""
            end
            item.description = entity.description or ""
            bucket[#bucket + 1] = item
        end
    end
    return snapshot
end

return Store
