--[[--
X-Ray 拉取：综合拉取 / 选词补全 / 手动增量。

@module koplugin.book.xray.fetch
--]]

local AI = require("ai")
local Context = require("xray.context")
local DbQueue = require("utils.db.queue")
local Prompts = require("xray.prompts")
local Store = require("xray.store")
local Text = require("utils.text")

local Fetch = {}

local function progressPercent(ui, page)
    local document = ui and ui.document
    local total = document and (document.getPageCount and document:getPageCount())
    total = tonumber(total) or 0
    page = tonumber(page) or 0
    if total <= 0 or page <= 0 then return 1 end
    return math.max(1, math.min(100, math.floor(page * 100 / total + 0.5)))
end

local function bookMeta(identity)
    local book = identity and identity.book or {}
    return Text.trim(book.title), Text.trim(book.authors or book.author)
end

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
    local timeline = {}
    for _, item in ipairs(type(decoded.timeline) == "table" and decoded.timeline or {}) do
        local chapter = Text.trim(item.chapter)
        local event = Text.trim(item.event)
        if chapter ~= "" and event ~= "" then
            timeline[#timeline + 1] = { chapter = chapter, event = event }
        end
    end
    return incoming, timeline, Text.trim(decoded.book_type)
end

local function persist(identity, incoming, timeline, toc, page, book_type, cb)
    local existing = Store.loadEntities(identity)
    local merged = Store.mergeEntities(existing, incoming)
    local aligned = Store.alignTimeline(timeline, toc)
    -- 增量时保留旧 timeline：按 chapter 合并
    local old_timeline = Store.loadTimeline(identity)
    local by_chapter = {}
    for _, ev in ipairs(old_timeline) do
        by_chapter[Text.trim(ev.chapter):lower()] = ev
    end
    for _, ev in ipairs(aligned) do
        by_chapter[Text.trim(ev.chapter):lower()] = ev
    end
    local combined = {}
    for _, ev in pairs(by_chapter) do
        combined[#combined + 1] = ev
    end
    table.sort(combined, function(a, b)
        local sa, sb = tonumber(a.sort_idx) or 0, tonumber(b.sort_idx) or 0
        if sa ~= sb then return sa < sb end
        return (tonumber(a.page) or 0) < (tonumber(b.page) or 0)
    end)

    DbQueue.run(function()
        assert(Store.saveEntities(identity, merged), "failed to save xray entities")
        assert(Store.saveTimeline(identity, combined), "failed to save xray timeline")
        assert(Store.saveMeta(identity, page, book_type ~= "" and book_type or nil),
            "failed to save xray meta")
    end, {
        on_done = function()
            cb({
                characters = Store.loadEntities(identity, "character"),
                locations = Store.loadEntities(identity, "location"),
                timeline = Store.loadTimeline(identity),
            })
        end,
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
    local meta = Store.loadMeta(identity)
    if not opts.force and meta and meta.last_fetch_page and meta.last_fetch_page > 0 then
        local entities = Store.loadEntities(identity)
        if #entities > 0 or #Store.loadTimeline(identity) > 0 then
            cb({
                characters = Store.loadEntities(identity, "character"),
                locations = Store.loadEntities(identity, "location"),
                timeline = Store.loadTimeline(identity),
                cached = true,
            })
            return nil
        end
    end

    local ctx = Context.forAnalysis(ui)
    local title, author = bookMeta(identity)
    local progress = progressPercent(ui, ctx.page)
    local messages = {
        { role = "system", content = Prompts.system },
        { role = "user", content = Prompts.comprehensive(
            title, author, progress, ctx.book_text, ctx.chapter_samples) },
    }
    return AI.jsonExtract(messages, { max_tokens = 8000, timeout = 180 }, function(decoded, err)
        if not decoded then cb(nil, err); return end
        local incoming, timeline, book_type = cleanPayload(decoded)
        persist(identity, incoming, timeline, ctx.toc, ctx.page, book_type, cb)
    end)
end

--- 自上次拉取页起做增量补充。
---@param ui table
---@param identity BookIdentity
---@param cb fun(result: table|nil, err: any)
---@return table|nil
function Fetch.incremental(ui, identity, cb)
    if not AI.isConfigured() then
        cb(nil, "AI is not configured")
        return nil
    end
    local meta = Store.loadMeta(identity)
    local start_page = (meta and meta.last_fetch_page or 0) + 1
    local page = Context.currentPage(ui)
    if page < start_page then
        cb({
            characters = Store.loadEntities(identity, "character"),
            locations = Store.loadEntities(identity, "location"),
            timeline = Store.loadTimeline(identity),
            cached = true,
        })
        return nil
    end

    local ctx = Context.forAnalysis(ui, { start_page = start_page, end_page = page })
    local title, author = bookMeta(identity)
    local progress = progressPercent(ui, page)
    local known_chars, known_locs = {}, {}
    for _, e in ipairs(Store.loadEntities(identity, "character")) do
        known_chars[#known_chars + 1] = "- " .. e.name
    end
    for _, e in ipairs(Store.loadEntities(identity, "location")) do
        known_locs[#known_locs + 1] = "- " .. e.name
    end
    local messages = {
        { role = "system", content = Prompts.system },
        { role = "user", content = Prompts.incremental(
            title, author, progress, ctx.book_text, ctx.chapter_samples,
            table.concat(known_chars, "\n"), table.concat(known_locs, "\n")) },
    }
    return AI.jsonExtract(messages, { max_tokens = 6000, timeout = 180 }, function(decoded, err)
        if not decoded then cb(nil, err); return end
        local incoming, timeline, book_type = cleanPayload(decoded)
        persist(identity, incoming, timeline, ctx.toc, page, book_type, cb)
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
    -- 本地别名命中则免请求
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
    local messages = {
        { role = "system", content = Prompts.system },
        { role = "user", content = Prompts.singleWord(word, ctx.book_text, ctx.chapter_samples) },
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
        else
            row = cleanCharacter(item)
        end
        if not row then
            cb(nil, "invalid entity")
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
