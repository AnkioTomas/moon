--[[--
AI 阅读上下文：选区所在句子与段落、当前可见页、本章开头到当前页之前的正文（过长保留末尾）。

只取读者已经读到的内容：前文止于当前页，不取后文。

@module koplugin.book.reader.context
--]]

local Text = require("utils.text")

local Context = {}

local PRIOR_TEXT_LIMIT = 24000
local VISIBLE_TEXT_LIMIT = 12000
local PARAGRAPH_LIMIT = 4000
local CHAPTER_TEXT_LIMIT = 64000

local SENTENCE_STOPS = { "。", "！", "？", "!", "?", ".", "\n" }
local SENTENCE_CLOSERS = { "”", "」", "』", "）", "\"", "'", ")" }

-- 选区常落在这些行内元素里，段落要跳到它们外面的块元素。
local INLINE_TAGS = {
    a = true, abbr = true, b = true, big = true, cite = true, code = true, em = true,
    font = true, i = true, mark = true, q = true, rt = true, ruby = true, s = true,
    small = true, span = true, strong = true, sub = true, sup = true, u = true,
}

--- 取阅读会话维护的当前页码。
---@return integer
local function currentPage()
    local session = require("reader.session").current()
    return session and session.page or 0
end

--- 取某页正文：getTextBoxes 优先，退回 getPageText；结果可能是字符串或嵌套词框表。
---@param ui table|nil ReaderUI
---@param page integer|nil
---@return string 取不到时空串
local function pageText(ui, page)
    local document = ui and ui.document
    if not document or not page or page < 1 then return "" end
    local boxes
    if document.getTextBoxes then
        local ok, result = pcall(document.getTextBoxes, document, page)
        if ok then boxes = result end
    end
    if not boxes and document.getPageText then
        local ok, result = pcall(document.getPageText, document, page)
        if ok then boxes = result end
    end
    if type(boxes) == "string" then
        return Text.trim(Text.normalizeNewlines(boxes))
    end
    local parts = {}
    --- 递归收集词框里的文本（word / text 字段优先），最多下探 5 层防环。
    ---@param depth integer
    local function walk(value, depth)
        if depth > 5 then return end
        if type(value) == "string" then
            if value ~= "" then parts[#parts + 1] = value end
        elseif type(value) == "table" then
            if type(value.word) == "string" then
                parts[#parts + 1] = value.word
            elseif type(value.text) == "string" then
                parts[#parts + 1] = value.text
            else
                for index, item in ipairs(value) do walk(item, depth + 1) end
            end
        end
    end
    walk(boxes, 0)
    return Text.trim(Text.normalizeNewlines(table.concat(parts, " ")))
end

---@param s string
---@param max_bytes integer
---@return string
local function tailUtf8(s, max_bytes)
    if #s <= max_bytes then
        return s
    end
    local start = math.max(1, #s - max_bytes)
    while start <= #s do
        local piece = s:sub(start)
        if #piece <= max_bytes and Text.isValidUtf8(piece) then
            return piece
        end
        start = start + 1
    end
    return Text.truncateUtf8(s, max_bytes)
end

--- 当前可见页正文与页码；滚动文档按屏幕坐标取字。
---@param ui table|nil
---@param page integer|nil 分页文档的页码，缺省取阅读会话页码
---@return string|nil, integer
function Context.visibleText(ui, page)
    if not ui then return nil, 0 end
    local document = ui.document
    if not document then return nil, 0 end
    page = page or currentPage()
    local text
    if ui.rolling and document.getTextFromPositions then
        local view = ui.view
        local dimen = view and view.dimen
        local width = dimen and dimen.w
        local height = dimen and dimen.h
        if not width or not height then
            local screen = require("device").screen
            width, height = screen:getWidth(), screen:getHeight()
        end
        local ok, result = pcall(document.getTextFromPositions, document,
            { x = 0, y = 0 }, { x = width, y = height }, true)
        text = ok and result and result.text or nil
    else
        text = pageText(ui, page)
    end
    text = Text.trim(Text.normalizeNewlines(text))
    if text == "" then return nil, page end
    return Text.truncateUtf8(text, VISIBLE_TEXT_LIMIT), page
end

--- 本章起始页；没有目录（如单章文件）时为 1。
---@param ui table
---@param page integer
---@return integer
local function chapterStart(ui, page)
    local toc = ui.toc
    if not toc or not toc.getPreviousChapter then return 1 end
    if toc:isChapterStart(page) then return page end
    return toc:getPreviousChapter(page) or 1
end

--- [start_page, end_page) 区间的正文；区间为空返回空串。
--- 固定版式逐页取字很慢：给了 head 时只从头取够 head 字节、从尾取够 tail 字节，中间跳过的页以「……」相隔。
---@param ui table
---@param start_page integer
---@param end_page integer
---@param head integer|nil 开头至少取这么多字节；nil = 全取
---@param tail integer|nil 结尾至少取这么多字节（与 head 一起给）
---@return string
function Context.pagesText(ui, start_page, end_page, head, tail)
    if end_page <= start_page then
        return ""
    end
    local document = ui.document
    -- CRE 没有逐页取字接口，只能按两页起点的 xpointer 取区间文本。
    if ui.rolling and document.getPageXPointer then
        local ok, text = pcall(function()
            return document:getTextFromXPointers(
                document:getPageXPointer(start_page), document:getPageXPointer(end_page))
        end)
        return ok and Text.trim(Text.normalizeNewlines(text)) or ""
    end
    local first, last = {}, {}
    local lo, hi, used = start_page, end_page - 1, 0
    while lo <= hi and (not head or used < head) do
        local text = pageText(ui, lo)
        lo = lo + 1
        if text ~= "" then first[#first + 1], used = text, used + #text end
    end
    used = 0
    while lo <= hi and used < (tail or 0) do
        local text = pageText(ui, hi)
        hi = hi - 1
        if text ~= "" then table.insert(last, 1, text); used = used + #text end
    end
    local out = table.concat(first, "\n\n")
    if #last == 0 then return out end
    return out .. (lo <= hi and "\n……\n" or "\n\n") .. table.concat(last, "\n\n")
end

--- 整章正文：offset 0 = 当前页所在章，1 = 下一章（含读者没读到的部分，只给按章识别用）。
--- 没有目录时只有 offset 0 且取整份文档；没有下一章、取不到字时 nil。超长章保留开头 CHAPTER_TEXT_LIMIT 字节。
---@param ui table
---@param page integer
---@param offset 0|1
---@return string|nil
function Context.chapterText(ui, page, offset)
    local document = ui.document
    local count = document:getPageCount()
    local toc = ui.toc
    local start, stop = 1, count
    if toc and toc.toc and #toc.toc > 0 then
        start = chapterStart(ui, page)
        if offset == 1 then start = toc:getNextChapter(start) end
        if not start then return nil end
        stop = toc:getNextChapter(start) or count
    elseif offset ~= 0 then
        return nil
    end
    -- CRE 取到区间末页起点，固定版式逐页取字要把末页算进去。
    local last = (stop == count and not ui.rolling) and count + 1 or stop
    local text = Context.pagesText(ui, start, last, 24000, 12000)
    if text == "" then return nil end
    return Text.truncateUtf8(text, CHAPTER_TEXT_LIMIT)
end

--- 本章开头到当前页之前的正文（不含当前页），超过 limit 字节保留末尾。
---@param ui table
---@param end_page integer
---@param limit integer|nil 缺省 PRIOR_TEXT_LIMIT
---@return string
function Context.priorText(ui, end_page, limit)
    limit = limit or PRIOR_TEXT_LIMIT
    local start_page = chapterStart(ui, end_page)
    if end_page <= start_page then
        return ""
    end
    if ui.rolling and ui.document.getPageXPointer then
        return tailUtf8(Context.pagesText(ui, start_page, end_page), limit)
    end
    local parts = {}
    local total = 0
    for page = end_page - 1, start_page, -1 do
        local text = pageText(ui, page)
        if text ~= "" then
            local room = limit - total
            if #text > room then
                text = tailUtf8(text, room)
            end
            if text ~= "" then
                table.insert(parts, 1, text)
                total = total + #text
            end
            if total >= limit then
                break
            end
        end
    end
    return table.concat(parts, "\n\n")
end

--- 组装 X-Ray 分析上下文。
---@param ui table
---@param prior_limit integer|nil 前文字节上限，缺省 PRIOR_TEXT_LIMIT
---@return { current_page: string, prior_text: string, page: integer }
function Context.forAnalysis(ui, prior_limit)
    local page = currentPage()
    local visible, visible_page = Context.visibleText(ui)
    if visible_page and visible_page > 0 then
        page = visible_page
    end
    return {
        current_page = visible or pageText(ui, page),
        prior_text = Context.priorText(ui, page, prior_limit),
        page = page,
    }
end

--- 选区 xpointer 所在块元素：去掉 text() 段，再跳出行内元素。
---@param xp string 如 /body/DocFragment[3]/body/div/p[12]/em/text().5
---@return string
function Context.blockXPointer(xp)
    local path = xp:gsub("/text%(%).*$", ""):gsub("%.%d+$", "")
    while true do
        local parent, tag = path:match("^(.+)/([%a][%w]*)[^/]*$")
        if not parent or not INLINE_TAGS[tag:lower()] then
            return path
        end
        path = parent
    end
end

--- 句末标点 stop_at 之后紧跟的右引号、右括号一并算进这一句，返回新的结束字节。
---@param s string
---@param stop_at integer
---@return integer
local function skipClosers(s, stop_at)
    local extended = true
    while extended do
        extended = false
        for _idx, closer in ipairs(SENTENCE_CLOSERS) do
            if s:sub(stop_at + 1, stop_at + #closer) == closer then
                stop_at = stop_at + #closer
                extended = true
            end
        end
    end
    return stop_at
end

--- 句子起点：在 first 之前最后一个句末标点（连同右引号）之后；没有则为 1。
---@param s string
---@param first integer
---@return integer
local function sentenceStart(s, first)
    local last = 0
    for _idx, stop in ipairs(SENTENCE_STOPS) do
        local init = 1
        while true do
            local found, finish = s:find(stop, init, true)
            if not found or finish >= first then break end
            if finish > last then last = finish end
            init = finish + 1
        end
    end
    if last == 0 then return 1 end
    return math.min(skipClosers(s, last), first - 1) + 1
end

--- 从 init 起第一个句末标点（连同右引号）的结束字节；没有则为 #s。
---@param s string
---@param init integer
---@return integer
local function sentenceEnd(s, init)
    local stop_at
    for _idx, stop in ipairs(SENTENCE_STOPS) do
        local _first, finish = s:find(stop, init, true)
        if finish and (not stop_at or finish < stop_at) then stop_at = finish end
    end
    if not stop_at then return #s end
    return skipClosers(s, stop_at)
end

--- needle 在 s 里不重叠出现的次数。
---@param s string
---@param needle string
---@return integer
local function countPlain(s, needle)
    local n, init = 0, 1
    while true do
        local _first, last = s:find(needle, init, true)
        if not last then return n end
        n, init = n + 1, last + 1
    end
end

--- 段落中包含选中文字的整句；段落里找不到选中文字时返回选中文字本身。
---@param paragraph string
---@param selected string
---@param skip integer|nil 选区之前段落里同样文字已出现的次数（同一个词在段里出现多次时定位到选中的那一处）
---@return string
function Context.sentence(paragraph, selected, skip)
    if selected == "" then return selected end
    local first, last = paragraph:find(selected, 1, true)
    if not first then return selected end
    for _idx = 1, skip or 0 do
        local next_first, next_last = paragraph:find(selected, last + 1, true)
        if not next_first then break end
        first, last = next_first, next_last
    end
    local start = sentenceStart(paragraph, first)
    return Text.trim(paragraph:sub(start, sentenceEnd(paragraph, last + 1)))
end

--- 划词上下文：选中文字、所在句子、所在段落。分页文档（PDF 等）没有 DOM，段落为空、句子即选中文字。
---@param ui table ReaderUI
---@param selected { text: string, pos0: string|table|nil }
---@return { text: string, sentence: string, paragraph: string }
function Context.selection(ui, selected)
    -- 选中文字、段落、段前文字按同一规则规范换行，跨行选区的出现次数才对得上。
    local text = Text.trim(Text.normalizeNewlines(selected.text))
    local paragraph, skip = "", 0
    local pos0 = selected.pos0
    if ui.rolling and type(pos0) == "string" and text ~= "" then
        local block = Context.blockXPointer(pos0)
        paragraph = Text.trim(Text.normalizeNewlines(ui.document:getTextFromXPointer(block) or ""))
        skip = countPlain(Text.normalizeNewlines(ui.document:getTextFromXPointers(block, pos0) or ""), text)
    end
    return {
        text = text,
        sentence = Context.sentence(paragraph, text, skip),
        paragraph = Text.truncateUtf8(paragraph, PARAGRAPH_LIMIT),
    }
end

Context.currentPage = currentPage

return Context
