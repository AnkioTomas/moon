--[[--
lockscreen.components.current：当前阅读主体的信息布局。

@module tests.lockscreen.components.current_spec
--]]

local Assert = require("support.assert")

local book = {
    title = "测试书名",
    authors = "测试作者",
    chapter_title = "第3章 继续阅读",
    cover = "/covers/test.png",
    percent = 35,
    page = 70,
    total_pages = 200,
}

package.preload["lockscreen.context"] = function()
    return { currentBook = function() return book end }
end
package.loaded["lockscreen.components.current"] = nil
package.loaded["lockscreen.context"] = nil

local Current = require("lockscreen.components.current")
local blocks = Current.blocks{
    x = 20, y = 30, w = 440, h = 180,
    pad = 16, text_x = 36, text_w = 408, radius = 10,
}

local texts = {}
local cover
local bars = 0
for _, block in ipairs(blocks) do
    if block.text then texts[#texts + 1] = block.text end
    if block.kind == "image" then cover = block end
    if block.kind == "bar" then bars = bars + 1 end
end

local function hasText(value)
    for _, text in ipairs(texts) do
        if text == value then return true end
    end
    return false
end

Assert.is_true(hasText(book.title))
Assert.is_true(hasText(book.authors))
Assert.is_true(hasText("章节 · 继续阅读"))
Assert.is_true(hasText("70 / 200 页"))
Assert.not_nil(cover)
Assert.eq(cover.path, book.cover)
Assert.eq(bars, 1)

book.total_pages = 0
local no_pages = Current.blocks{
    x = 20, y = 30, w = 440, h = 180,
    pad = 16, text_x = 36, text_w = 408, radius = 10,
}
local percent_lines = 0
local no_page_text
for _, block in ipairs(no_pages) do
    if block.text and block.text:find("%", 1, true) then percent_lines = percent_lines + 1 end
    if block.text == "页数暂无" then no_page_text = true end
end
Assert.eq(percent_lines, 1)
Assert.is_true(no_page_text)
