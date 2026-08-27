--[[--
X-Ray 阅读上下文：当前可见页 + 其前最多 2000 字节正文。

@module koplugin.book.xray.context
--]]

local Text = require("utils.text")

local Context = {}

local PRIOR_TEXT_LIMIT = 2000
local VISIBLE_TEXT_LIMIT = 12000

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

---@param s string
---@param max_bytes integer
---@return string
local function tailUtf8(s, max_bytes)
    s = tostring(s or "")
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

--- 当前页之前的正文（不含当前页），最多 limit 字节。
---@param ui table
---@param end_page integer|nil
---@param limit integer|nil
---@return string
function Context.priorText(ui, end_page, limit)
    limit = limit or PRIOR_TEXT_LIMIT
    end_page = end_page or currentPage(ui)
    if end_page <= 1 then
        return ""
    end
    local parts = {}
    local total = 0
    for page = end_page - 1, 1, -1 do
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
---@return { current_page: string, prior_text: string, page: integer }
function Context.forAnalysis(ui)
    local page = currentPage(ui)
    local visible, visible_page = Context.visibleText(ui)
    if visible_page and visible_page > 0 then
        page = visible_page
    end
    return {
        current_page = visible or pageText(ui, page) or "",
        prior_text = Context.priorText(ui, page, PRIOR_TEXT_LIMIT),
        page = page,
    }
end

Context.currentPage = currentPage

return Context
