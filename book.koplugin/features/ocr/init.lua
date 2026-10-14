--[[--
文字识别（OCR）：为 KOReader 内置 Tesseract 下载识别模型，并让扫描版 PDF / DjVu 上长按选中的文字
走进月读划词菜单（复制、翻译、AI 等按钮都拿到识别出的文字）。

只对按页排版的文档生效；EPUB 等重排文档本来就有文字层，不触发识别。

@module koplugin.book.features.ocr.init
--]]

local Ocr = {}

--- 划词菜单弹出前：选区没有文字但有框（扫描页）时先做一次识别，把结果写进 selected_text.text。
--- 识别不出来就提示（没装模型给「去下载」）并清除选区，返回 false 让调用方不再弹菜单。
---@param highlight table ReaderHighlight
---@return boolean 是否继续弹菜单
function Ocr.fillSelection(highlight)
    local sel = highlight.selected_text
    if not sel or (sel.text and sel.text ~= "") then return true end
    local doc = highlight.ui and highlight.ui.document
    local page = highlight.hold_pos and highlight.hold_pos.page
    if not (doc and page and sel.sboxes and doc.getOCRText) then return true end
    local text = doc:getOCRText(page, sel.sboxes)
    if (not text or text == "") and doc.getOCRWord then
        local words = {}
        for _idx, sbox in ipairs(sel.sboxes) do
            words[#words + 1] = doc:getOCRWord(page, { sbox = sbox }) or ""
        end
        text = table.concat(words)
    end
    if text and text ~= "" then
        sel.text = text
        return true
    end
    require("features.ocr.ui").promptMissing()
    if highlight.clear then highlight:clear() end
    return false
end

return Ocr
