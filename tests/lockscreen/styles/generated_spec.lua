--[[--
本地生成锁屏：阅读统计、阅读账单与物理书架布局数据。

@module tests.lockscreen.styles.generated_spec
--]]

local Assert = require("support.assert")
local writes = {}

package.preload["lockscreen.background"] = function()
    return { ensure = function(cb) cb("/bg.jpg") end }
end
-- bookshelf 不再走 Background；其余样式仍用 stub
package.preload["lockscreen.context"] = function()
    return {
        currentBook = function()
            return {
                title = "测试书", authors = "作者", percent = 42,
                page = 42, total_pages = 100, chapter_idx = 2, chapter_count = 8,
                total_seconds = 3600,
            }
        end,
        bill = function()
            return {
                period = "7d", start_ts = 100, end_ts = 100 + 7 * 86400,
                summary = { total_seconds = 7200, book_count = 1, pages = 20 },
                books = { { stable_id = "b1", title = "测试书", authors = "作者", percent = 42, seconds = 7200 } },
                days = { { ymd = "2024-01-01", seconds = 7200, pages = 20 } },
            }
        end,
        bookshelf = function()
            return {
                reading = {
                    { stable_id = "r1", title = "在读书", cover = nil },
                    { stable_id = "r2", title = "另一本", cover = "/c2.png" },
                },
                covers = {
                    { stable_id = "c1", title = "封面甲", cover = "/a.png" },
                    { stable_id = "c2", title = "封面乙", cover = nil },
                    { stable_id = "c3", title = "封面丙", cover = "/c.png" },
                },
            }
        end,
    }
end
package.preload["lockscreen.render"] = function()
    return {
        size = function() return 480, 800 end,
        write = function(path, bg, blocks)
            writes[#writes + 1] = { path = path, bg = bg, blocks = blocks }
            return true
        end,
    }
end
package.preload["utils.paths"] = function()
    return { screensaverDir = function() return "/lock" end }
end
package.preload["ffi/util"] = function()
    return {
        template = function(s, ...)
            local args = { ... }
            return (s:gsub("%%(%d+)", function(i) return tostring(args[tonumber(i)] or "") end))
        end,
    }
end
package.preload["ffi/blitbuffer"] = function()
    local c = function() return {} end
    return {
        COLOR_BLACK = c(), COLOR_WHITE = c(),
        COLOR_GRAY_2 = c(), COLOR_GRAY_3 = c(), COLOR_GRAY_4 = c(),
        COLOR_GRAY_5 = c(), COLOR_GRAY_6 = c(), COLOR_GRAY_7 = c(),
        COLOR_GRAY_9 = c(), COLOR_GRAY_B = c(), COLOR_DARK_GRAY = c(),
        COLOR_GRAY_D = c(), COLOR_GRAY_E = c(),
    }
end

local Reading = require("lockscreen.styles.reading")
local Bill = require("lockscreen.styles.bill")
local Bookshelf = require("lockscreen.styles.bookshelf")
local reading_ok, bill_ok, shelf_ok
Reading.fetch(function(ok) reading_ok = ok end)
Bill.fetch(function(ok) bill_ok = ok end)
Bookshelf.fetch(function(ok) shelf_ok = ok end)
Assert.is_true(reading_ok)
Assert.is_true(bill_ok)
Assert.is_true(shelf_ok)
Assert.eq(writes[1].bg, "/bg.jpg")
local has_progress, has_chart, has_book = false, false, false
for _, block in ipairs(writes[1].blocks) do
    has_progress = has_progress or (block.kind == "bar" and block.value == 0.42)
end
for _, block in ipairs(writes[2].blocks) do
    has_chart = has_chart or block.kind == "vbar"
    has_book = has_book or (type(block.text) == "string" and block.text:find("测试书", 1, true) ~= nil)
end
Assert.is_true(has_progress)
Assert.is_true(has_chart)
Assert.is_true(has_book)

local shelf = writes[3]
Assert.eq(shelf.path, "/lock/bookshelf.png")
local spines, images, boards = 0, 0, 0
for _, block in ipairs(shelf.blocks) do
    if block.kind == "spine" then spines = spines + 1 end
    if block.kind == "image" then images = images + 1 end
    -- 层板本体偏厚，约 10～20px
    if block.kind == "panel" and block.height and block.height >= 8 and block.height <= 24
        and block.color then
        boards = boards + 1
    end
end
Assert.is_true(spines >= 1)
Assert.is_true(images >= 1)
Assert.is_true(boards >= 4)
-- 不再叠壁纸
Assert.is_nil(shelf.bg)
