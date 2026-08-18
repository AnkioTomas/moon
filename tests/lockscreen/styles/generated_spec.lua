--[[--
本地生成锁屏：阅读统计与阅读账单布局数据。

@module tests.lockscreen.styles.generated_spec
--]]

local Assert = require("support.assert")
local writes = {}

package.preload["lockscreen.background"] = function()
    return { ensure = function(cb) cb("/bg.jpg") end }
end
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
    return { lockScreenDir = function() return "/lock" end }
end
package.preload["ffi/util"] = function()
    return {
        template = function(s, ...)
            local args = { ... }
            return (s:gsub("%%(%d+)", function(i) return tostring(args[tonumber(i)] or "") end))
        end,
    }
end

local Reading = require("lockscreen.styles.reading")
local Bill = require("lockscreen.styles.bill")
local reading_ok, bill_ok
Reading.fetch(function(ok) reading_ok = ok end)
Bill.fetch(function(ok) bill_ok = ok end)
Assert.is_true(reading_ok)
Assert.is_true(bill_ok)
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
