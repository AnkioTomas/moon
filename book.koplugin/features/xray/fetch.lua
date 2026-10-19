--[[--
X-Ray 拉取：综合拉取 / 选词补全。

两阶段：库里还没有实体时只给书名 / 作者 / 简介让模型凭通用知识生成（known=false 或无结果时回落章节增量）；
已有实体后按本章开头到当前页的正文增量刷新，结果须在正文里 grounding，别名补进已有实体。划词只取当前页附近文字。

@module koplugin.book.features.xray.fetch
--]]

require("l10n").apply()

local AI = require("ai")
local Context = require("reader.context")
local Prompts = require("features.xray.prompts")
local Store = require("features.xray.store")
local XrayDB = require("features.xray.db")
local Text = require("utils.text")
local _ = require("gettext")

local Fetch = {}

local MIN_GROUND_LEN = 2
local INTRO_LIMIT = 1500
local LOOKUP_PRIOR_LIMIT = 2000
--- 提示词最多带前面几章的摘要。
local RECAP_CHAPTERS = 5
--- 全书分析每段正文的字节上限。
local SCAN_CHUNK = 32000
--- 一次产出人物、地点、术语三段 JSON，推理模型的思考还要占额度，8K 实测会被截断。
local BULK_MAX_TOKENS = 16000

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
---@return boolean|nil
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
---@return { characters: table[], locations: table[], terms: table[], cached: boolean|nil }
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

--- 当前章之前的章节摘要；不在任何章或没有摘要时 nil。
---@param identity BookIdentity
---@return string|nil
local function storySoFar(identity)
    local idx = require("reader.session").chapterIndex()
    return idx and AI.priorSummaries(identity, idx, RECAP_CHAPTERS) or nil
end

---@return integer 1..100
local function progressPercent()
    local session = require("reader.session").current()
    local percent = session and type(session.percent) == "number" and session.percent or 0
    return math.max(1, math.floor(percent + 0.5))
end

--- 章节增量：按当前页 + 前文更新，结果必须在正文中 grounding。
---@param ui table
---@param identity BookIdentity
---@param existing table[]
---@param cb fun(result: table|nil, err: any)
---@return table|nil
local function fromContext(ui, identity, existing, cb)
    local ctx = Context.forAnalysis(ui)
    if ctx.current_page == "" and ctx.prior_text == "" then
        cb(nil, "no text")
        return nil
    end
    local title, author = bookMeta(identity)
    local messages = {
        { role = "system", content = Prompts.system },
        { role = "user", content = Prompts.comprehensive(
            title, author, progressPercent(), ctx.current_page, ctx.prior_text, Store.promptSnapshot(existing),
            storySoFar(identity)) },
    }
    return AI.jsonExtract(messages, { localize = true, partial = true, max_tokens = BULK_MAX_TOKENS, timeout = require("http.timeout").ai(1.5) }, function(decoded, err)
        if not decoded then cb(nil, err); return end
        persist(identity, filterGrounded(cleanPayload(decoded), readingContext(ctx)), cb)
    end)
end

--- 首次初始化：凭书籍基本信息走模型通用知识，不做 grounding；
--- 模型不认识这本书或没给出实体时回落到章节增量。
---@param ui table
---@param identity BookIdentity
---@param cb fun(result: table|nil, err: any)
---@return table|nil
local function fromKnowledge(ui, identity, cb)
    local title, author = bookMeta(identity)
    if title == "" then
        return fromContext(ui, identity, {}, cb)
    end
    local intro = Text.truncateUtf8(Text.trim((identity.book or {}).intro), INTRO_LIMIT)
    local messages = {
        { role = "system", content = Prompts.system },
        { role = "user", content = Prompts.knowledge(title, author, intro) },
    }
    return AI.jsonExtract(messages, { localize = true, partial = true, max_tokens = BULK_MAX_TOKENS, timeout = require("http.timeout").ai(1.5) }, function(decoded, err)
        if not decoded then cb(nil, err); return end
        local incoming = decoded.known ~= false and cleanPayload(decoded) or {}
        if #incoming == 0 then
            fromContext(ui, identity, {}, cb)
            return
        end
        persist(identity, incoming, cb)
    end)
end

--- 综合拉取 X-Ray：库里没有实体时凭通用知识初始化，之后按章节上下文增量更新；
--- 已有数据且非 force 时直接回缓存。
---@param ui table
---@param identity BookIdentity
---@param opts { force?: boolean }|nil
---@param cb fun(result: table|nil, err: any)
---@return table|nil
function Fetch.comprehensive(ui, identity, opts, cb)
    opts = opts or {}
    if not AI.isConfigured() then
        cb(nil, _("AI 未配置"))
        return nil
    end
    local existing = XrayDB.list(identity.source_id, identity.stable_id)
    if #existing == 0 then
        return fromKnowledge(ui, identity, cb)
    end
    if not opts.force then
        local result = fetchResult(existing)
        result.cached = true
        cb(result)
        return nil
    end
    return fromContext(ui, identity, existing, cb)
end

--- 把正文切成不超过 size 字节的段：优先在后半段的换行处断开，否则退到 UTF-8 字符边界。
---@param text string
---@param size integer
---@return string[]
function Fetch.chunks(text, size)
    local out, pos, len = {}, 1, #text
    while pos <= len do
        local stop = math.min(pos + size - 1, len)
        if stop < len then
            local cut = text:sub(pos, stop):match("^.*()\n")
            if cut and cut > size / 2 then
                stop = pos + cut - 1
            else
                local byte = text:byte(stop + 1)
                while stop > pos and byte >= 0x80 and byte < 0xC0 do
                    stop = stop - 1
                    byte = text:byte(stop + 1)
                end
            end
        end
        local chunk = Text.trim(text:sub(pos, stop))
        if chunk ~= "" then out[#out + 1] = chunk end
        pos = stop + 1
    end
    return out
end

--- 全书正文的指纹：同一本书的同一版正文分段结果不变，续扫游标才对得上。
---@param text string
---@param chunks string[]
---@return string
local function scanDigest(text, chunks)
    return #text .. ":" .. #chunks
end

--- 上次没分析完、这次可以接着来的段数；没有或正文变了时 nil。
---@param identity BookIdentity
---@return { done: integer, total: integer }|nil
function Fetch.scanProgress(identity)
    local cursor = XrayDB.scanCursor(identity.source_id, identity.stable_id)
    if cursor and cursor.done > 0 and cursor.done < cursor.total then return cursor end
end

--- 全书分析的任务体（`workers.tasks` 的 run）：逐段请求 AI，每段结果当场合并落库并推进游标（xray_scan）。
--- 退避重试、休眠 / 断网后重跑、下次重新点「分析全书」都从没做完的那段接着来；全部完成删游标。
--- 提示词只带本段提到的已收录实体，否则实体越积越多会撑爆上下文。
---@param identity BookIdentity
---@param text string 全书正文
---@return fun(report: fun(text: string|nil, count: integer|nil, total: integer|nil), done: fun(result: table)): table
function Fetch.scanBook(identity, text)
    local chunks = Fetch.chunks(text, SCAN_CHUNK)
    local digest = scanDigest(text, chunks)
    local title, author = bookMeta(identity)
    local cursor = XrayDB.scanCursor(identity.source_id, identity.stable_id)
    local index = cursor and cursor.digest == digest and cursor.done + 1 or 1
    return function(report, done)
        local request
        local first = index
        --- 结束本次尝试；推进过就让页内标记重扫一次（每段都刷会一直闪阅读页）。
        local function finish(result)
            result.progressed = index > first
            if result.ok then XrayDB.clearScanCursor(identity.source_id, identity.stable_id) end
            if result.progressed then require("features.xray.marks").invalidate() end
            done(result)
        end
        local function step()
            report(_("正在分析全书"), index - 1, #chunks)
            if index > #chunks then
                finish({ ok = true })
                return
            end
            local chunk = chunks[index]
            local existing = filterGrounded(XrayDB.list(identity.source_id, identity.stable_id), chunk)
            local messages = {
                { role = "system", content = Prompts.system },
                { role = "user", content = Prompts.comprehensive(
                    title, author, math.floor(index * 100 / #chunks), chunk, "", Store.promptSnapshot(existing)) },
            }
            request = AI.jsonExtract(messages, { localize = true, partial = true, max_tokens = BULK_MAX_TOKENS, timeout = require("http.timeout").ai(1.5) }, function(decoded, err)
                if not decoded then finish({ ok = false, err = err }); return end
                local ok, save_err = pcall(mergeAndSave, identity, filterGrounded(cleanPayload(decoded), chunk))
                if not ok then finish({ ok = false, err = save_err }); return end
                XrayDB.saveScanCursor(identity.source_id, identity.stable_id, digest, index, #chunks)
                index = index + 1
                step()
            end)
        end
        step()
        return { cancel = function() if request then request.cancel() end end }
    end
end

--- 本地实体库按名字 / 别名（不分大小写）找词；不联网、不需要 AI。
---@param entities table[]
---@param word string 已 trim
---@return table|nil
local function findIn(entities, word)
    local normalized_word = word:lower()
    for _idx, entity in ipairs(entities) do
        if Text.trim(entity.name):lower() == normalized_word then return entity end
        for _alias_idx, alias in ipairs(entity.aliases) do
            if Text.trim(alias):lower() == normalized_word then return entity end
        end
    end
end

--- 只查本地实体库；没收录返回 nil。
---@param identity BookIdentity
---@param word string
---@return table|nil
function Fetch.findLocal(identity, word)
    return findIn(XrayDB.list(identity.source_id, identity.stable_id), Text.trim(word))
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
        cb(nil, _("AI 未配置"))
        return nil
    end
    local entities = XrayDB.list(identity.source_id, identity.stable_id)
    local hit = findIn(entities, word)
    if hit then
        cb(hit)
        return nil
    end

    local ctx = Context.forAnalysis(ui, LOOKUP_PRIOR_LIMIT)
    local title, author = bookMeta(identity)
    local existing = Store.promptSnapshot(entities)
    local messages = {
        { role = "system", content = Prompts.system },
        { role = "user", content = Prompts.singleWord(
            word, title, author, ctx.current_page, ctx.prior_text, existing, storySoFar(identity)) },
    }
    -- 选词补全量小，上限走「AI token 上限」配置（ai_max_tokens）。
    return AI.jsonExtract(messages, { localize = true }, function(decoded, err)
        if not decoded then cb(nil, err); return end
        if decoded.is_valid == false then
            cb(nil, Text.trim(decoded.error_message) ~= "" and decoded.error_message or "not an entity")
            return
        end
        local kind = (decoded.type == "location" or decoded.type == "term") and decoded.type or "character"
        local row = cleanEntity(kind, decoded.item)
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
