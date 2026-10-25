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
local LOOKUP_PRIOR_LIMIT = 2000
--- 一次产出人物、地点、术语三段 JSON，推理模型的思考还要占额度，8K 实测会被截断。
local BULK_MAX_TOKENS = 16000
--- 识别档位（book_xray_quality）：前情摘要章数、是否带本页之前的正文、每次实体数量上限、输出 token 上限、附加规则。
local PROFILES = {
    save = { recap = 0, prior = false, caps = { 10, 5, 5 }, max_tokens = 10000,
        rule = "description 不超过 40 字，aliases 最多 2 个；只输出本页新出现或有重要新信息的实体。" },
    standard = { recap = 5, prior = true, caps = { 25, 15, 15 }, max_tokens = BULK_MAX_TOKENS },
    high = { recap = 10, prior = true, caps = { 40, 25, 25 }, max_tokens = BULK_MAX_TOKENS,
        rule = "description 写详实（80 到 150 字）：身份、与其他人物的关系、关键经历；有别名或译名变体务必收全。" },
}

local function profile()
    return PROFILES[require("utils.settings").get("features.xray").book_xray_quality] or PROFILES.standard
end
--- 本章 / 全书分析每段正文的字节上限（约 4000 汉字）。请求是非流式的，输出量随段长增长：
--- 原先 32000 字节一段，一次要产出几十个实体，推理模型常在整包超时内写不完，表现为「本章 / 本书超时」。
local SCAN_CHUNK = 12000

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
    -- 模型可能漏掉 aliases 或给成字符串
    if kind ~= "location" and type(item.aliases) == "table" then
        for _idx, alias in ipairs(item.aliases) do
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
        for item_index, item in ipairs(decoded[section.key] or {}) do
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

--- 合并并落库；用户删过的实体（名字或别名在墓碑里）不再加回，手动补全（manual）除外并清掉墓碑。
---@param identity BookIdentity
---@param incoming table[]
---@param manual boolean|nil
local function mergeAndSave(identity, incoming, manual)
    local source_id, stable_id = identity.source_id, identity.stable_id
    if manual then
        for _idx, row in ipairs(incoming) do XrayDB.restore(source_id, stable_id, row.kind, row.name) end
    else
        local removed = XrayDB.removedSet(source_id, stable_id)
        local kept = {}
        for _idx, row in ipairs(incoming) do
            local dropped = removed[row.kind .. "\0" .. Text.trim(row.name):lower()]
            for _alias_idx, alias in ipairs(row.aliases) do
                dropped = dropped or removed[row.kind .. "\0" .. Text.trim(alias):lower()]
            end
            if not dropped then kept[#kept + 1] = row end
        end
        incoming = kept
    end
    local merged = Store.mergeEntities(XrayDB.list(source_id, stable_id), incoming)
    assert(XrayDB.replace(source_id, stable_id, merged), "failed to save xray entities")
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
    local recap = profile().recap
    return idx and recap > 0 and AI.priorSummaries(identity, idx, recap) or nil
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
    if not profile().prior then
        ctx.prior_text = ""
    end
    local messages = {
        { role = "system", content = Prompts.system },
        { role = "user", content = Prompts.comprehensive(
            title, author, progressPercent(), ctx.current_page, ctx.prior_text, Store.promptSnapshot(existing),
            storySoFar(identity), profile()) },
    }
    return AI.jsonExtract(messages, { localize = true, max_tokens = profile().max_tokens, timeout = require("http.timeout").ai(1.5) }, function(decoded, err)
        if not decoded then cb(nil, err); return end
        persist(identity, filterGrounded(cleanPayload(decoded), readingContext(ctx)), cb)
    end)
end

--- 按当前位置增量更新 X-Ray：本页 + 本章前文，结果须在正文里 grounding。
---@param ui table
---@param identity BookIdentity
---@param cb fun(result: table|nil, err: any)
---@return table|nil
function Fetch.comprehensive(ui, identity, cb)
    if not AI.isConfigured() then
        cb(nil, _("AI 未配置"))
        return nil
    end
    return fromContext(ui, identity, XrayDB.list(identity.source_id, identity.stable_id), cb)
end

local SENTENCE_ENDS = { "。", "！", "？", "…", ". ", "! ", "? " }

--- window 里最后一个句末标点之后的字节位置；没有返回 nil。
---@param window string
---@return integer|nil
local function lastSentenceEnd(window)
    local best
    for _idx, mark in ipairs(SENTENCE_ENDS) do
        local from = 1
        while true do
            local at = window:find(mark, from, true)
            if not at then break end
            best = math.max(best or 0, at + #mark - 1)
            from = at + 1
        end
    end
    return best
end

--- 把正文切成不超过 size 字节的段：优先在后半段的换行处断开，其次句末标点，最后退到 UTF-8 字符边界。
---@param text string
---@param size integer
---@return string[]
function Fetch.chunks(text, size)
    local out, pos, len = {}, 1, #text
    while pos <= len do
        local stop = math.min(pos + size - 1, len)
        if stop < len then
            local window = text:sub(pos, stop)
            local cut = window:match("^.*()\n")
            local sentence = lastSentenceEnd(window)
            if cut and cut > size / 2 then
                stop = pos + cut - 1
            elseif sentence and sentence > size / 2 then
                stop = pos + sentence - 1
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

--- 按章识别：整章正文切段逐段请求 AI，每段结果当场合并落库；结果须在本章正文里 grounding。
---@param identity BookIdentity
---@param text string 本章正文
---@param cb fun(result: table|nil, err: any)
---@return table 带 cancel 的句柄
function Fetch.chapter(identity, text, cb)
    local chunks = Fetch.chunks(text, SCAN_CHUNK)
    local title, author = bookMeta(identity)
    local source_id, stable_id = identity.source_id, identity.stable_id
    local index, request, cancelled = 1, nil, false
    local function step()
        if cancelled then return end
        if index > #chunks then
            cb(fetchResult(XrayDB.list(source_id, stable_id)))
            return
        end
        local chunk = chunks[index]
        local existing = filterGrounded(XrayDB.list(source_id, stable_id), chunk)
        local messages = {
            { role = "system", content = Prompts.system },
            { role = "user", content = Prompts.comprehensive(
                title, author, progressPercent(), chunk, "", Store.promptSnapshot(existing),
                storySoFar(identity), profile()) },
        }
        request = AI.jsonExtract(messages, { localize = true, max_tokens = profile().max_tokens, timeout = require("http.timeout").ai(1.5) }, function(decoded, err)
            if cancelled then return end
            if not decoded then cb(nil, err); return end
            local ok, save_err = pcall(mergeAndSave, identity, filterGrounded(cleanPayload(decoded), chunk))
            if not ok then cb(nil, save_err); return end
            index = index + 1
            step()
        end)
    end
    step()
    return { cancel = function()
        cancelled = true
        if request then request.cancel() end
    end }
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
                    title, author, math.floor(index * 100 / #chunks), chunk, "", Store.promptSnapshot(existing),
                    nil, profile()) },
            }
            request = AI.jsonExtract(messages, { localize = true, max_tokens = profile().max_tokens, timeout = require("http.timeout").ai(1.5) }, function(decoded, err)
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
        local ok, save_err = pcall(mergeAndSave, identity, { row }, true)
        if ok then cb(row) else cb(nil, save_err) end
    end)
end

return Fetch
