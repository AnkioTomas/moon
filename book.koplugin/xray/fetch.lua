--[[--
X-Ray 拉取：综合拉取 / 选词补全。

@module koplugin.book.xray.fetch
--]]

local AI = require("ai")
local Context = require("xray.context")
local Prompts = require("xray.prompts")
local Store = require("xray.store")
local XrayDB = require("db.xray")
local Text = require("utils.text")

local Fetch = {}

local MIN_GROUND_LEN = 2

local payload_sections = {
    { kind = "character", key = "characters" },
    { kind = "location", key = "locations" },
    { kind = "term", key = "terms" },
}

---@param ctx table
---@return string
local function readingContext(ctx)
    return table.concat({ ctx.current_page, ctx.prior_text }, "\n\n")
end

---@param needle string
---@param haystack string
---@return boolean
local function appearsInText(needle, haystack)
    needle = Text.trim(needle)
    if needle == "" or #needle < MIN_GROUND_LEN then
        return false
    end
    return haystack:find(needle, 1, true) ~= nil
end

--- name 或任一 alias 须在上下文中出现；hint 用于划词（选中词本身已在文中）。
---@param row table
---@param context string
---@param hint string|nil
---@return boolean
local function isGrounded(row, context, hint)
    if appearsInText(row.name, context) then
        return true
    end
    for index, alias in ipairs(row.aliases) do
        if appearsInText(alias, context) then
            return true
        end
    end
    return hint and appearsInText(hint, context)
end

---@param incoming table[]
---@param context string
---@return table[]
local function filterGrounded(incoming, context)
    local out = {}
    for index, row in ipairs(incoming) do
        if isGrounded(row, context) then
            out[#out + 1] = row
        end
    end
    return out
end

--- 取书名与作者（供提示词），缺失时为空串。
---@param identity BookIdentity
---@return string title, string author
local function bookMeta(identity)
    local book = identity.book or {}
    return Text.trim(book.title), Text.trim(book.authors or book.author)
end

--- 把模型返回的实体规范成实体行；无名字返回 nil。
---@param kind "character"|"location"|"term"
---@param item table
---@return table|nil
local function cleanEntity(kind, item)
    local name = Text.trim(item.name)
    if name == "" then return nil end
    local aliases = {}
    if kind ~= "location" then
        for index, alias in ipairs(item.aliases) do
            alias = Text.trim(alias)
            if alias ~= "" then aliases[#aliases + 1] = alias end
        end
    end
    local entity = {
        kind = kind,
        name = name,
        aliases = aliases,
        description = Text.trim(item.description),
    }
    if kind == "character" then
        entity.role = Text.trim(item.role)
        entity.gender = Text.trim(item.gender)
        entity.occupation = Text.trim(item.occupation)
    end
    return entity
end

--- 把综合拉取返回的 characters/locations/terms 三段规范化并合成一张实体列表。
---@param decoded table 模型返回的 JSON 对象
---@return table[]
local function cleanPayload(decoded)
    local incoming = {}
    for section_index, section in ipairs(payload_sections) do
        for item_index, item in ipairs(decoded[section.key]) do
            local row = cleanEntity(section.kind, item)
            if row then incoming[#incoming + 1] = row end
        end
    end
    return incoming
end

--- 按三类实体组成返回给调用方的结果表。
---@param entities table[]
---@return { characters: table[], locations: table[], terms: table[] }
local function fetchResult(entities)
    local result = { characters = {}, locations = {}, terms = {} }
    local buckets = {
        character = result.characters,
        location = result.locations,
        term = result.terms,
    }
    for entity_index, entity in ipairs(entities) do
        local bucket = buckets[entity.kind]
        if bucket then
            bucket[#bucket + 1] = entity
        end
    end
    return result
end

---@param identity BookIdentity
---@param incoming table[]
local function mergeAndSave(identity, incoming)
    local merged = Store.mergeEntities(XrayDB.list(identity.source_id, identity.stable_id), incoming)
    assert(XrayDB.replace(identity.source_id, identity.stable_id, merged), "failed to save xray entities")
    return merged
end

---@param identity BookIdentity
---@param incoming table[]
---@param cb fun(result: table|nil, err: any)
local function persist(identity, incoming, cb)
    local ok, result = pcall(mergeAndSave, identity, incoming)
    if ok then cb(fetchResult(result)) else cb(nil, result) end
end

--- 综合拉取 X-Ray；已有数据且非 force 时直接回缓存。
---@param ui table
---@param identity BookIdentity
---@param opts { force?: boolean }|nil
---@param cb fun(result: table|nil, err: any)
---@return table|nil
function Fetch.comprehensive(ui, identity, opts, cb)
    opts = opts or {}
    if not AI.isConfigured() then
        cb(nil, "AI is not configured")
        return nil
    end
    local existing = XrayDB.list(identity.source_id, identity.stable_id)
    if not opts.force and #existing > 0 then
        local result = fetchResult(existing)
        result.cached = true
        cb(result)
        return nil
    end

    local ctx = Context.forAnalysis(ui)
    if ctx.current_page == "" and ctx.prior_text == "" then
        cb(nil, "no text")
        return nil
    end
    local title, author = bookMeta(identity)
    local session = require("ui.reader.session").current()
    local progress = math.max(1, math.floor(session.percent + 0.5))
    local existing_snapshot = Store.promptSnapshot(existing)
    local messages = {
        { role = "system", content = Prompts.system },
        { role = "user", content = Prompts.comprehensive(
            title, author, progress, ctx.current_page, ctx.prior_text, existing_snapshot) },
    }
    return AI.jsonExtract(messages, { max_tokens = 8000, timeout = 180 }, function(decoded, err)
        if not decoded then cb(nil, err); return end
        local context = readingContext(ctx)
        persist(identity, filterGrounded(cleanPayload(decoded), context), cb)
    end)
end

--- 选词查实体：本地别名命中免请求，否则 AI 补全并落库。
---@param ui table
---@param identity BookIdentity
---@param word string
---@param cb fun(item: table|nil, err: any)
---@return table|nil
function Fetch.lookupWord(ui, identity, word, cb)
    word = Text.trim(word)
    if word == "" then
        cb(nil, "empty word")
        return nil
    end
    if not AI.isConfigured() then
        cb(nil, "AI is not configured")
        return nil
    end
    local entities = XrayDB.list(identity.source_id, identity.stable_id)
    local normalized_word = word:lower()
    for index, entity in ipairs(entities) do
        if Text.trim(entity.name):lower() == normalized_word then
            cb(entity)
            return nil
        end
        for index, alias in ipairs(entity.aliases) do
            if Text.trim(alias):lower() == normalized_word then
                cb(entity)
                return nil
            end
        end
    end

    local ctx = Context.forAnalysis(ui)
    local title, author = bookMeta(identity)
    local existing = Store.promptSnapshot(entities)
    local messages = {
        { role = "system", content = Prompts.system },
        { role = "user", content = Prompts.singleWord(
            word, title, author, ctx.current_page, ctx.prior_text, existing) },
    }
    return AI.jsonExtract(messages, { max_tokens = 800 }, function(decoded, err)
        if not decoded then cb(nil, err); return end
        if decoded.is_valid == false then
            cb(nil, Text.trim(decoded.error_message) ~= "" and decoded.error_message or "not an entity")
            return
        end
        local item = decoded.item
        local row
        if decoded.type == "location" then
            row = cleanEntity("location", item)
        elseif decoded.type == "term" then
            row = cleanEntity("term", item)
        else
            row = cleanEntity("character", item)
        end
        if not row then
            cb(nil, "invalid entity")
            return
        end
        local context = readingContext(ctx)
        if not isGrounded(row, context, word) then
            cb(nil, "name not found in text")
            return
        end
        local ok, save_err = pcall(mergeAndSave, identity, { row })
        if ok then cb(row) else cb(nil, save_err) end
    end)
end

return Fetch
