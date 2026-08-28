--[[--
X-Ray 拉取：综合拉取 / 选词补全。

@module koplugin.book.xray.fetch
--]]

local AI = require("ai")
local Context = require("xray.context")
local DbQueue = require("utils.db.queue")
local Prompts = require("xray.prompts")
local Store = require("xray.store")
local Text = require("utils.text")

local Fetch = {}

local MIN_GROUND_LEN = 2

---@param ctx table
---@return string
local function readingContext(ctx)
    return table.concat({ ctx.current_page or "", ctx.prior_text or "" }, "\n\n")
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
    for _, alias in ipairs(row.aliases or {}) do
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
    for _, row in ipairs(incoming or {}) do
        if isGrounded(row, context) then
            out[#out + 1] = row
        end
    end
    return out
end

--- 当前阅读进度百分比（1~100），页数或页码不可用时按 1 算。
---@param ui table|nil ReaderUI
---@param page integer|nil
---@return integer
local function progressPercent(ui, page)
    local document = ui and ui.document
    local total = document and (document.getPageCount and document:getPageCount())
    total = tonumber(total) or 0
    page = tonumber(page) or 0
    if total <= 0 or page <= 0 then return 1 end
    return math.max(1, math.min(100, math.floor(page * 100 / total + 0.5)))
end

--- 取书名与作者（供提示词），缺失时为空串。
---@param identity BookIdentity|nil
---@return string title, string author
local function bookMeta(identity)
    local book = identity and identity.book or {}
    return Text.trim(book.title), Text.trim(book.authors or book.author)
end

--- 把模型返回的人物项规范成实体行（去空白别名）；无名字返回 nil。
---@param item table|nil
---@return table|nil
local function cleanCharacter(item)
    local name = Text.trim(item and item.name)
    if name == "" then return nil end
    local aliases = {}
    for _, alias in ipairs(type(item.aliases) == "table" and item.aliases or {}) do
        alias = Text.trim(alias)
        if alias ~= "" then aliases[#aliases + 1] = alias end
    end
    return {
        kind = "character",
        name = name,
        aliases = aliases,
        payload = {
            role = Text.trim(item.role),
            description = Text.trim(item.description),
            gender = Text.trim(item.gender),
            occupation = Text.trim(item.occupation),
        },
    }
end

--- 把模型返回的地点项规范成实体行（地点不带别名）；无名字返回 nil。
---@param item table|nil
---@return table|nil
local function cleanLocation(item)
    local name = Text.trim(item and item.name)
    if name == "" then return nil end
    return {
        kind = "location",
        name = name,
        aliases = {},
        payload = {
            description = Text.trim(item.description),
        },
    }
end

--- 把模型返回的术语项规范成实体行（去空白别名）；无名字返回 nil。
---@param item table|nil
---@return table|nil
local function cleanTerm(item)
    local name = Text.trim(item and item.name)
    if name == "" then return nil end
    local aliases = {}
    for _, alias in ipairs(type(item.aliases) == "table" and item.aliases or {}) do
        alias = Text.trim(alias)
        if alias ~= "" then aliases[#aliases + 1] = alias end
    end
    return {
        kind = "term",
        name = name,
        aliases = aliases,
        payload = {
            description = Text.trim(item.description),
        },
    }
end

--- 把综合拉取返回的 characters/locations/terms 三段规范化并合成一张实体列表。
---@param decoded table 模型返回的 JSON 对象
---@return table[]
local function cleanPayload(decoded)
    local incoming = {}
    for _, item in ipairs(type(decoded.characters) == "table" and decoded.characters or {}) do
        local row = cleanCharacter(item)
        if row then incoming[#incoming + 1] = row end
    end
    for _, item in ipairs(type(decoded.locations) == "table" and decoded.locations or {}) do
        local row = cleanLocation(item)
        if row then incoming[#incoming + 1] = row end
    end
    for _, item in ipairs(type(decoded.terms) == "table" and decoded.terms or {}) do
        local row = cleanTerm(item)
        if row then incoming[#incoming + 1] = row end
    end
    return incoming
end

--- 按三类实体读库，组成返回给调用方的结果表。
---@param identity BookIdentity
---@return { characters: table[], locations: table[], terms: table[] }
local function fetchResult(identity)
    return {
        characters = Store.loadEntities(identity, "character"),
        locations = Store.loadEntities(identity, "location"),
        terms = Store.loadEntities(identity, "term"),
    }
end

---@param identity BookIdentity
---@param incoming table[]
---@param cb fun(result: table|nil, err: any)
local function persist(identity, incoming, cb)
    DbQueue.run(function()
        local merged = Store.mergeEntities(Store.loadEntities(identity), incoming)
        assert(Store.saveEntities(identity, merged), "failed to save xray entities")
    end, {
        on_done = function() cb(fetchResult(identity)) end,
        on_failed = function(err) cb(nil, err) end,
    })
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
    if not opts.force and #Store.loadEntities(identity) > 0 then
        local result = fetchResult(identity)
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
    local progress = progressPercent(ui, ctx.page)
    local existing = Store.promptSnapshot(identity)
    local messages = {
        { role = "system", content = Prompts.system },
        { role = "user", content = Prompts.comprehensive(
            title, author, progress, ctx.current_page, ctx.prior_text, existing) },
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
    for _, entity in ipairs(Store.loadEntities(identity)) do
        if Text.trim(entity.name):lower() == word:lower() then
            cb(entity)
            return nil
        end
        for _, alias in ipairs(entity.aliases or {}) do
            if Text.trim(alias):lower() == word:lower() then
                cb(entity)
                return nil
            end
        end
    end

    local ctx = Context.forAnalysis(ui)
    local title, author = bookMeta(identity)
    local existing = Store.promptSnapshot(identity)
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
        local item = decoded.item or {}
        local row
        if decoded.type == "location" then
            row = cleanLocation(item)
        elseif decoded.type == "term" then
            row = cleanTerm(item)
        else
            row = cleanCharacter(item)
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
        DbQueue.run(function()
            local merged = Store.mergeEntities(Store.loadEntities(identity), { row })
            assert(Store.saveEntities(identity, merged), "failed to save lookup entity")
        end, {
            on_done = function() cb(row) end,
            on_failed = function(save_err) cb(nil, save_err) end,
        })
    end)
end

return Fetch
