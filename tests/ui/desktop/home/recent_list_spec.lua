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
package.preload["ui.components.pagestrip"] = function()
    return {
        bandH = function() return 20 end,
        clamp = function(page, pages)
            return math.max(1, math.min(pages, page))
        end,
        widget = function(opts)
            pager = {
                page = opts.page,
                pages = opts.pages,
                handlers = { on_prev = opts.on_prev, on_next = opts.on_next },
            }
            return pager
        end,
    }
end

local dirty = 0
package.preload["ui/uimanager"] = function()
    return { setDirty = function() dirty = dirty + 1 end }
end
package.preload["ui/event"] = function()
    return { new = function(_, name) return { handler = "on" .. name } end }
end

local shelf_reading = {}
package.preload["book.catalog"] = function()
    return {
        recentShelf = function()
            return nil, shelf_reading, nil
        end,
    }
end

local List = require("ui.desktop.home.views.recent_list")
local list = List:new()
local range = list:heightRange({}, { width = 600 })
Assert.eq(range.min, 218)
Assert.eq(range.preferred, 404)
Assert.eq(range.max, 590)
Assert.eq(range.step, 186)

local opened
package.preload["ui.desktop.detail"] = function()
    return { open = function(_, book) opened = book end }
end
local view_updates = 0
local desktop = {
    updateView = function() view_updates = view_updates + 1 end,
}
local books = {}
for i = 1, 5 do books[i] = { title = "book" .. i } end
shelf_reading = books
list.lifecycle.state = "Resume"
local part = list:build({ desktop = desktop, source = { id = "local" } }, {
    width = 600,
    height = 404,
    desktop = desktop,
    y = 40,
})
Assert.eq(part:getSize().h, 404)
Assert.len(covers, 4)
Assert.eq(covers[1].w, 100)
Assert.eq(taps[1].w, 100)
Assert.eq(taps[1].h, 176)
Assert.eq(pager.page, 1)
Assert.eq(pager.pages, 2)
Assert.eq(texts[#texts], "最近阅读 · 5")
taps[1].callback()
Assert.eq(opened, books[1])
covers = {}
pager.handlers.on_next()
Assert.eq(list.page, 2)
Assert.eq(view_updates, 0)
Assert.eq(dirty, 1)
Assert.len(covers, 1)
Assert.eq(pager.page, 2)
list:onEvent("source_changed")
Assert.is_nil(list.page)

local pauses = 0
list.content_widget = { handleEvent = function(_, event)
    Assert.eq(event.handler, "onHomePause")
    pauses = pauses + 1
end }
list:onPause()
list:onDestroy()
Assert.eq(pauses, 1)
Assert.is_nil(list.widget)

return true
