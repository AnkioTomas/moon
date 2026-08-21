--[[--
从 ReaderUI 提取当前可见页文本。滚动文档按屏幕坐标取文本，分页文档展平文字框。

@module koplugin.book.ai.context
--]]

local Text = require("utils.text")

local Context = {}
local MAX_BYTES = 12000

local function flatten(value, out, depth)
    if depth > 5 then return end
    if type(value) == "string" then
        if value ~= "" then out[#out + 1] = value end
    elseif type(value) == "table" then
        if type(value.word) == "string" then
            out[#out + 1] = value.word
            return
        end
        if type(value.text) == "string" then
            out[#out + 1] = value.text
            return
        end
        for _, item in ipairs(value) do flatten(item, out, depth + 1) end
    end
end

--- 当前可见页文本与页码；滚动文档按屏幕坐标取字。
---@param ui table|nil
---@return string|nil, integer
function Context.currentPage(ui)
    local document = ui and ui.document
    if not document then return nil, 0 end
    local page = tonumber(ui.getCurrentPage and ui:getCurrentPage())
        or tonumber(document.getCurrentPage and document:getCurrentPage()) or 0
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
        local boxes
        if document.getTextBoxes then
            local ok, result = pcall(document.getTextBoxes, document, page)
            if ok then boxes = result end
        end
        if not boxes and document.getPageText then
            local ok, result = pcall(document.getPageText, document, page)
            if ok then boxes = result end
        end
        local parts = {}
        flatten(boxes, parts, 0)
        text = table.concat(parts, " ")
    end
    text = Text.trim(Text.normalizeNewlines(text))
    if text == "" then return nil, page end
    return Text.truncateUtf8(text, MAX_BYTES), page
end

return Context
