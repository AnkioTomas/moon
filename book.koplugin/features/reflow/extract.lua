--[[--
从正在阅读的文档里逐页取纯文本，供重排转 EPUB。

流式文档（CREngine：EPUB/FB2/HTML/MOBI/AZW3/DOC/RTF/CHM…）没有整本导出接口：前 N-1 页取相邻页
XPointer 之间的文本，末页跳到页首后按屏幕范围取，取完放回阅读位置。
固定版式（PDF/DjVu）逐页取文字层，按行拼词；扫描版没有文字层，取不到就报错。
每页一个 nextTick，不卡界面。结果交给 text2epub 做章节识别与物理行合并；转换有损，
不保留图片、脚注和原样式。

@module koplugin.book.features.reflow.extract
--]]

require("l10n").apply()

local UIManager = require("ui/uimanager")
local Text = require("utils.text")
local _ = require("gettext")

local Extract = {}

--- 只消除相邻渲染页完全相同的边界行。
---@param pages string[]
---@param raw string
local function appendPage(pages, raw)
    local page = Text.normalizeNewlines(raw):gsub("^\n+", ""):gsub("\n+$", "")
    if page == "" then
        return
    end
    local previous = pages[#pages]
    if previous then
        local last_line = previous:match("([^\n]+)$")
        local first_line, rest = page:match("^([^\n]+)\n(.*)$")
        if not first_line then
            first_line, rest = page, ""
        end
        if last_line ~= nil and first_line == last_line then
            page = rest
        end
    end
    if page ~= "" then
        pages[#pages + 1] = page
    end
end

--- 流式文档第 page 页：非末页取相邻两页 xpointer 之间，末页只能跳过去按屏幕范围取。
---@param document table
---@param page integer
---@param count integer
---@return string|nil
local function rollingPage(document, page, count)
    if page < count then
        return document:getTextFromXPointers(document:getPageXPointer(page), document:getPageXPointer(page + 1))
    end
    document:gotoPage(page)
    local Screen = require("device").screen
    local range = document:getTextFromPositions(
        { x = 0, y = 0 }, { x = Screen:getWidth(), y = Screen:getHeight() }, true)
    return range and range.text
end

--- 固定版式第 page 页：词框按行拼接；相邻两词都是 ASCII 才补空格，中日韩文字不加。
---@param document table
---@param page integer
---@return string
local function pagingPage(document, page)
    local lines = {}
    for _line_idx, line in ipairs(document:getPageTextBoxes(page) or {}) do
        local words, previous = {}, nil
        for _word_idx, box in ipairs(line) do
            local word = box.word
            if word and word ~= "" then
                if previous and previous:match("[%w%p]$") and word:match("^%w") then
                    words[#words + 1] = " "
                end
                words[#words + 1] = word
                previous = word
            end
        end
        lines[#lines + 1] = table.concat(words)
    end
    return table.concat(lines, "\n")
end

--- 取出 ui 当前文档的全部文字；可取消，取消后 cb 不再触发。
---@param ui table ReaderUI
---@param cb fun(text: string|nil, err: any)
---@return { cancel: fun() }
function Extract.run(ui, cb)
    local document = ui.document
    local rolling = ui.rolling ~= nil
    local count = document:getPageCount()
    -- 末页 gotoPage 会挪走阅读位置，收尾时放回。
    local restore_xp = rolling and document:getXPointer() or nil
    local pages = {}
    local cancelled = false

    ---@param text string|nil
    ---@param err any
    local function finish(text, err)
        if ui.document == document and restore_xp then document:gotoXPointer(restore_xp) end
        cb(text, err)
    end

    ---@param page integer
    local function step(page)
        if cancelled then return end
        if ui.document ~= document then return finish(nil, _("文档已关闭")) end
        -- 坏页上 CREngine / MuPDF 会抛错：整次提取作废并告诉用户，不带着半本书继续。
        local ok, chunk
        if rolling then
            ok, chunk = pcall(rollingPage, document, page, count)
        else
            ok, chunk = pcall(pagingPage, document, page)
        end
        if not ok or type(chunk) ~= "string" then
            return finish(nil, _("无法提取文字") .. ": " .. tostring(chunk))
        end
        appendPage(pages, chunk)
        if page < count then
            UIManager:nextTick(require("ui.guard").wrap("reflow extract", function() step(page + 1) end))
            return
        end
        local text = table.concat(pages, "\n")
        if Text.trim(text) == "" then
            return finish(nil, _("文档没有可提取的文字"))
        end
        finish(text)
    end

    UIManager:nextTick(require("ui.guard").wrap("reflow extract", function()
        if count < 1 and not cancelled then return finish(nil, _("文档没有可提取的文字")) end
        step(1)
    end))
    return { cancel = function() cancelled = true end }
end

return Extract
