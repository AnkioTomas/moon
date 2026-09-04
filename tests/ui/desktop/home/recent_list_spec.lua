--[[-- 最近阅读书架按分配高度分页并铺满列宽。 --]]

local Assert = require("support.assert")

local texts = {}
local taps = {}
local covers = {}
local pager

local function widget()
    return { new = function(_, opts) return opts or {} end }
end

for _, name in ipairs({
    "ui/widget/container/centercontainer",
    "ui/widget/container/framecontainer",
    "ui/widget/container/leftcontainer",
    "ui/widget/horizontalgroup",
    "ui/widget/horizontalspan",
    "ui/widget/verticalgroup",
    "ui/widget/verticalspan",
    "ui/geometry",
}) do
    package.preload[name] = widget
end
package.preload["ui/widget/textwidget"] = function()
    return {
        new = function(_, opts)
            texts[#texts + 1] = opts.text
            return opts
        end,
    }
end
package.preload["ffi/blitbuffer"] = function() return { COLOR_BLACK = 0 } end
package.preload["gettext"] = function() return function(text) return text end end
package.preload["ffi/util"] = function()
    return {
        template = function(text, value)
            return (text:gsub("%%1", tostring(value)))
        end,
    }
end
package.preload["ui.components.bookui"] = function()
    return {
        sz = function(value) return value end,
        gridCoverMaxH = function() return 200 end,
        denseCoverMetrics = function()
            return 100, 100, 150, 2, 8, 10, 176
        end,
        face = function() return {} end,
        muted = function() return 128 end,
    }
end
package.preload["ui.components.bookinfo"] = function()
    return {
        cover = function(_, _, book, w, h)
            covers[#covers + 1] = { book = book, w = w, h = h }
            return {}
        end,
        title = function(book) return book.title end,
        tappable = function(w, h, callback)
            taps[#taps + 1] = { w = w, h = h, callback = callback }
            return {}
        end,
    }
end
package.preload["ui.components.pager"] = function()
    return {
        bandH = function() return 20 end,
        clamp = function(page, pages)
            return math.max(1, math.min(pages, page))
        end,
        band = function(_, page, pages, handlers)
            pager = { page = page, pages = pages, handlers = handlers }
            return pager
        end,
    }
end

local List = require("ui.desktop.home.components.recent_list")
local range = List.heightRange({}, {}, { width = 600 })
Assert.eq(range.min, 218)
Assert.eq(range.preferred, 404)
Assert.eq(range.max, 590)
Assert.eq(range.step, 186)

local opened
local rebuilds = 0
local desktop = {
    showDetail = function(_, book) opened = book end,
    rebuild = function() rebuilds = rebuilds + 1 end,
}
local books = {}
for i = 1, 5 do books[i] = { title = "book" .. i } end
local part = List.build({ desktop = desktop }, { reading = books }, {
    width = 600,
    height = 404,
    desktop = desktop,
})
Assert.eq(part.height, 404)
Assert.len(covers, 4)
Assert.eq(covers[1].w, 100)
Assert.eq(taps[1].w, 100)
Assert.eq(taps[1].h, 176)
Assert.eq(pager.page, 1)
Assert.eq(pager.pages, 2)
Assert.eq(texts[#texts], "最近阅读 · 5")
taps[1].callback()
Assert.eq(opened, books[1])
pager.handlers.on_next()
Assert.eq(desktop._home_reading_page, 2)
Assert.eq(rebuilds, 1)

return true
