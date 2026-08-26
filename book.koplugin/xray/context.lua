--[[--
X-Ray spoiler-safe 文本采样：当前进度内的微上下文 + 章节短采样。

@module koplugin.book.xray.context
--]]

local Text = require("utils.text")

local Context = {}

local BOOK_TEXT_LIMIT = 20000
local CHAPTER_BUDGET = 80000
local PER_CHAPTER_SAMPLE = 1200
local VISIBLE_TEXT_LIMIT = 12000

local function flattenTOC(nodes, flat)
    flat = flat or {}
    if not nodes then return flat end
    for _, node in ipairs(nodes) do
        if type(node) == "table" then
            flat[#flat + 1] = node
            if #node > 0 then
                flattenTOC(node, flat)
            elseif node.sub_item_table then
                flattenTOC(node.sub_item_table, flat)
            elseif node.children then
                flattenTOC(node.children, flat)
            end
        end
    end
    return flat
end

local function currentPage(ui)
    if not ui then return 0 end
    if type(ui.getCurrentPage) == "function" then
        local ok, page = pcall(function() return ui:getCurrentPage() end)
        if ok and page then return tonumber(page) or 0 end
    end
    local document = ui.document
    if document and document.getCurrentPage then
        local ok, page = pcall(document.getCurrentPage, document)
        if ok and page then return tonumber(page) or 0 end
    end
    return 0
end

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
                for _, item in ipairs(value) do walk(item, depth + 1) end
            end
        end
    end
    walk(boxes, 0)
    return Text.trim(Text.normalizeNewlines(table.concat(parts, " ")))
end

--- 当前可见页正文与页码；滚动文档按屏幕坐标取字。
---@param ui table|nil
---@return string|nil, integer
function Context.visibleText(ui)
    local document = ui and ui.document
    if not document then return nil, 0 end
    local page = currentPage(ui)
    local text
    if ui.rolling and document.getTextFromPositions then
        local width = ui.view and ui.view.dimen and ui.view.dimen.w
        local height = ui.view and ui.view.dimen and ui.view.dimen.h
        if not width or not height then
            local ok, Device = pcall(require, "device")
            local screen = ok and Device and Device.screen
            width = screen and screen:getWidth() or 100000
            height = screen and screen:getHeight() or 100000
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

--- 最近正文（不超过 limit 字节），止于当前页。
---@param ui table
---@param limit integer|nil
---@param end_page integer|nil
---@return string, integer
function Context.bookText(ui, limit, end_page)
    limit = limit or BOOK_TEXT_LIMIT
    end_page = end_page or currentPage(ui)
    if end_page < 1 then
        local text = Context.visibleText(ui)
        return text or "", end_page
    end
    local chunks = {}
    local total = 0
    for page = end_page, 1, -1 do
        local text = pageText(ui, page)
        if text ~= "" then
            local piece = Text.truncateUtf8(text, limit - total)
            if piece ~= "" then
                table.insert(chunks, 1, piece)
                total = total + #piece
            end
            if total >= limit then break end
        end
    end
    return table.concat(chunks, "\n\n"), end_page
end

--- 已读章节采样：标题 + 短摘录。
---@param ui table
---@param end_page integer|nil
---@param start_page integer|nil 增量起点（含）；nil=从头
---@return string, table[] chapter titles with page
function Context.chapterSamples(ui, end_page, start_page)
    end_page = end_page or currentPage(ui)
    start_page = tonumber(start_page) or 1
    local document = ui and ui.document
    local toc = {}
    if document and document.getToc then
        local ok, raw = pcall(document.getToc, document)
        if ok then toc = flattenTOC(raw) end
    end

    local active = {}
    for _, chapter in ipairs(toc) do
        local page = tonumber(chapter.page)
        local title = Text.trim(chapter.title)
        if title ~= "" and page and page >= start_page and page <= end_page then
            active[#active + 1] = { title = title, page = page }
        end
    end

    local budget = CHAPTER_BUDGET
    if #active > 60 then
        budget = math.min(budget, 60000)
    elseif #active > 30 then
        budget = math.min(budget, 80000)
    end

    local per = PER_CHAPTER_SAMPLE
    if #active > 0 then
        per = math.max(400, math.floor(budget / #active))
        per = math.min(per, PER_CHAPTER_SAMPLE)
    end

    local parts = {}
    local used = 0
    for _, chapter in ipairs(active) do
        if used >= budget then break end
        local sample = Text.truncateUtf8(pageText(ui, chapter.page), per)
        local block = string.format("## %s (p.%d)\n%s", chapter.title, chapter.page, sample)
        parts[#parts + 1] = block
        used = used + #block
    end
    return table.concat(parts, "\n\n"), active
end

--- 组装综合分析用的书文与章节采样。
---@param ui table
---@param opts { start_page?: integer, end_page?: integer }|nil
---@return { book_text: string, chapter_samples: string, page: integer, toc: table[] }
function Context.forAnalysis(ui, opts)
    opts = opts or {}
    local page = opts.end_page or currentPage(ui)
    local book_text = Context.bookText(ui, BOOK_TEXT_LIMIT, page)
    local samples, toc = Context.chapterSamples(ui, page, opts.start_page)
    return {
        book_text = book_text,
        chapter_samples = samples,
        page = page,
        toc = toc,
    }
end

Context.currentPage = currentPage

return Context
