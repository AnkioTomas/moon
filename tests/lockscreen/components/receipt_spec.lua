--[[--
lockscreen 阅读票根：当前书统计映射与票据块结构。

@module tests.lockscreen.components.receipt_spec
--]]

local Assert = require("support.assert")

local current_book = {
    source_id = "moon",
    stable_id = "book-1",
    title = "测试书",
    authors = "测试作者",
    percent = 25,
    page = 50,
    total_pages = 200,
    total_seconds = 3600,
    buckets = {
        { key = os.date("%Y-%m-%d"), seconds = 1800, pages = 12 },
    },
}

package.preload["ffi/blitbuffer"] = function()
    return { COLOR_BLACK = 0, COLOR_WHITE = 255 }
end

package.preload["lockscreen.components.current"] = function()
    return { book = function(with_stats)
        Assert.is_true(with_stats)
        return current_book
    end }
end

local cover_book
package.preload["ui.components.bookinfo"] = function()
    return {
        cover = function(_, _, book, width, height, opts)
            cover_book = book
            Assert.is_true(opts.sync)
            Assert.is_false(opts.shadow)
            return {
                getSize = function() return { w = width, h = height } end,
                paintTo = function() end,
                free = function() end,
            }, width, height
        end,
    }
end

package.preload["lockscreen.components.util"] = function()
    return {
        MUTED = 3,
        DIM = 4,
        RULE = 5,
        duration = function(seconds) return tostring(math.floor(seconds / 60)) .. "m" end,
        progress = function(book)
            return book.percent, string.format("%d / %d 页", book.page, book.total_pages)
        end,
        emptyBlocks = function(_, title, message)
            return { { text = title }, { text = message } }
        end,
    }
end

package.loaded["lockscreen.components.receipt"] = nil
local Receipt = require("lockscreen.components.receipt")

Assert.eq(Receipt.id, "receipt")
Assert.is_false(Receipt.supports_narrow)
Assert.is_false(Receipt.supports_position)

local cache_key = Receipt.cache_key()
current_book.page = 51
Assert.is_true(Receipt.cache_key() ~= cache_key)
current_book.page = 50

local blocks = Receipt.blocks({
    x = 20, y = 30, w = 500, h = 700,
    text_x = 40, text_w = 460, pad = 20, radius = 10,
})
Assert.eq(blocks[1].kind, "panel")

local texts = {}
local barcode = 0
local cutouts = 0
local cover_block
local logo_block
local brand_block
local receipt_title
local duration_label
local summary_divider
for _, block in ipairs(blocks) do
    if block.text then texts[#texts + 1] = block.text end
    if block.kind == "vbar" then barcode = barcode + 1 end
    if block.kind == "cutout_circle" then cutouts = cutouts + 1 end
    if block.kind == "widget" then cover_block = block end
    if block.kind == "image" then logo_block = block end
    if block.text == "MOON READING" then brand_block = block end
    if block.text == "READ RECEIPT" then receipt_title = block end
    if block.text == "今日阅读时长" then duration_label = block end
    if block.kind == "rule" and block.width == 1 then summary_divider = block end
end
Assert.eq(cover_book, current_book)
Assert.not_nil(cover_block)
Assert.is_true(cover_block.height > cover_block.width)
Assert.matches(logo_block.file, "book%.koplugin/logo%.png$")
Assert.eq(brand_block.y + 8, logo_block.y + math.floor(logo_block.height / 2))
Assert.eq(receipt_title.x, 40)
Assert.is_true(receipt_title.y > logo_block.y + logo_block.height)
Assert.is_true(duration_label.x > summary_divider.x + 10)
Assert.contains(texts, "测试书")
Assert.contains(texts, "测试作者")
Assert.contains(texts, "50 / 200 页")
Assert.contains(texts, "12 页")
Assert.contains(texts, "30m")
Assert.is_true(barcode > 20)
Assert.is_true(cutouts > 4)

current_book = nil
local empty = Receipt.blocks({
    x = 0, y = 0, w = 100, h = 100,
    text_x = 10, text_w = 80, pad = 10, radius = 0,
})
Assert.eq(empty[1].text, "阅读票根")
Assert.eq(empty[2].text, "当前没有正在阅读的书籍")
