--[[--
lockscreen 书架：阅读优先、稳定身份去重与网格位置。

@module tests.lockscreen.components.bookshelf_spec
--]]

local Assert = require("support.assert")

local recent = {
    { stable_id = "a", title = "A", percent = 10 },
    { stable_id = "b", title = "B", percent = 100 },
    { stable_id = "a", title = "A duplicate", percent = 20 },
    { title = "missing id", percent = 10 },
    { stable_id = "", title = "empty id", percent = 10 },
}
local listed = {
    { stable_id = "c", title = "C", percent = 0 },
}
local db_sources = {}
local cover_ids = {}
local text_values = {}

package.preload["ffi/blitbuffer"] = function()
    return {
        COLOR_BLACK = 0,
        COLOR_WHITE = 255,
    }
end

package.preload["db.book"] = function()
    return {
        listBySource = function(source_id)
            db_sources[#db_sources + 1] = source_id
            return listed, #listed
        end,
    }
end
package.preload["book.catalog"] = function()
    return {
        recentBooks = function(source_id)
            db_sources[#db_sources + 1] = source_id
            return recent
        end,
    }
end

package.preload["lockscreen.components.library"] = function()
    return {
        activeSourceId = function() return "moon" end,
        shelfBook = function(row, source_id)
            return {
                source_id = source_id,
                stable_id = row.stable_id,
                title = row.title,
                percent = row.percent,
            }
        end,
    }
end

local function widgetClass(name)
    local class = {}
    function class:new(value)
        value = value or {}
        value.class = name
        return value
    end
    return class
end

package.preload["ui/widget/container/centercontainer"] = function()
    return widgetClass("center")
end
package.preload["ui/widget/container/framecontainer"] = function()
    return widgetClass("frame")
end
package.preload["ui/geometry"] = function()
    return { new = function(_, value) return value end }
end
package.preload["ui/widget/horizontalgroup"] = function()
    return widgetClass("horizontal")
end
package.preload["ui/widget/horizontalspan"] = function()
    return widgetClass("horizontal-span")
end
package.preload["ui/widget/verticalgroup"] = function()
    return widgetClass("vertical")
end
package.preload["ui/widget/verticalspan"] = function()
    return widgetClass("vertical-span")
end
package.preload["ui/widget/textwidget"] = function()
    local TextWidget = {}
    function TextWidget:new(value)
        text_values[#text_values + 1] = value.text
        value.getSize = function()
            return { w = #tostring(value.text) * 8, h = 20 }
        end
        return value
    end
    return TextWidget
end
package.preload["ui.components.bookui"] = function()
    return {
        sz = function(n) return n end,
        face = function() return {} end,
        muted = function() return 5 end,
        denseCoverMetrics = function()
            return 100, 80, 120, 2, 10, 20, 150
        end,
    }
end
package.preload["ui.components.bookinfo"] = function()
    return {
        cover = function(_, _, book)
            cover_ids[#cover_ids + 1] = book.stable_id
            return { book = book }
        end,
        title = function(book) return book.title end,
    }
end

package.loaded["lockscreen.components.bookshelf"] = nil
local Bookshelf = require("lockscreen.components.bookshelf")
local blocks = Bookshelf.blocks({ w = 240, h = 600 })

-- 缺失身份、空身份和重复行都不得进入可见书架；阅读中的 a 保持最前。
Assert.eq(#cover_ids, 3)
Assert.eq(cover_ids[1], "a")
Assert.eq(cover_ids[2], "b")
Assert.eq(cover_ids[3], "c")
Assert.contains(text_values, "共3本")
Assert.eq(db_sources[1], "moon")
Assert.eq(db_sources[2], "moon")

Assert.eq(#blocks, 5)
Assert.eq(blocks[1].kind, "panel")
Assert.eq(blocks[2].kind, "widget")

local expected = {
    { 10, 52 },
    { 120, 52 },
    { 10, 222 },
}
for i, point in ipairs(expected) do
    local block = blocks[i + 2]
    Assert.eq(block.kind, "widget")
    Assert.eq(block.x, point[1])
    Assert.eq(block.y, point[2])
    Assert.eq(block.width, 100)
    Assert.eq(block.height, 150)
end
