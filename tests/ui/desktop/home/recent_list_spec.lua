--[[-- 最近阅读书架：行列由设置决定，高度按行数固定。 --]]

local Assert = require("support.assert")

local texts = {}
local taps = {}
local covers = {}
local pager
local shown
local dirty = 0
local home = {
    home_recent_list_rows = 2,
    home_recent_list_cols = 4,
}

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
        denseCoverMetrics = function(_, _, opts)
            local cols = opts and opts.min_cols or 2
            local extra = opts and opts.title_extra or 0
            return 100, 100, 150, cols, 8, 10, 150 + extra
        end,
        face = function() return {} end,
        muted = function() return 128 end,
    }
end
local opened_detail
local opened_book
local open_done
package.preload["ui.desktop.detail"] = function()
    return { open = function(_, book) opened_detail = book end }
end
package.preload["book.open"] = function()
    return {
        book = function(_, book, on_done)
            opened_book = book
            open_done = on_done
        end,
    }
end
package.preload["ui.components.bookinfo"] = function()
    return {
        cover = function(_, _, book, w, h, opts)
            local widget = {}
            covers[#covers + 1] = { book = book, w = w, h = h, more = opts and opts.more, widget = widget }
            return widget
        end,
        openingBar = function()
            return { kind = "opening" }
        end,
        title = function(book) return book.title end,
        tappable = function(w, h, callback, on_hold)
            local tap = { dimen = { x = 0, y = 0, w = w, h = h } }
            taps[#taps + 1] = { w = w, h = h, callback = callback, on_hold = on_hold, widget = tap }
            return tap
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
package.preload["ui/uimanager"] = function()
    return {
        setDirty = function() dirty = dirty + 1 end,
        nextTick = function(_, cb) cb() end,
        show = function(_, widget) shown = widget end,
        close = function() end,
    }
end
package.preload["ui/event"] = function()
    return { new = function(_, name) return { handler = "on" .. name } end }
end
package.preload["ui/widget/buttondialog"] = function()
    return { new = function(_, opts) return opts end }
end
package.preload["ui/widget/spinwidget"] = function()
    return { new = function(_, opts) return opts end }
end
package.preload["utils.settings"] = function()
    return {
        get = function() return home end,
        saveSection = function(section_or_self, a, b)
            local values = b or a
            if type(values) == "table" then home = values end
        end,
    }
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
Assert.eq(List.rows(), 2)
Assert.eq(List.cols(), 4)
Assert.eq(List.showTitle(), true)
List.saveShowTitle(false)
Assert.eq(List.showTitle(), false)
List.saveShowTitle(true)
Assert.eq(List.showTitle(), true)
List.saveCols(2)
Assert.eq(List.cols(), 3)
List.saveCols(9)
Assert.eq(List.cols(), 8)
List.saveCols(4)
List.saveRows(0)
Assert.eq(List.rows(), 2)

local list = List:new()
local range = list:heightRange({}, { width = 600 })
Assert.eq(range.height, 404)
Assert.is_nil(range.fill)

List.saveRows(1)
range = list:heightRange({}, { width = 600 })
Assert.eq(range.height, 218)
List.saveRows(2)

local view_updates = 0
local events = {}
local refresh_statuses = {}
local desktop = {
    plugin = {},
    updateView = function() view_updates = view_updates + 1 end,
    onEvent = function(_, event, payload)
        events[#events + 1] = event
        if event == "refresh_status" then
            refresh_statuses[#refresh_statuses + 1] = payload
        end
    end,
}
local books = {}
for i = 1, 5 do books[i] = { title = "book" .. i } end
shelf_reading = books
list.lifecycle.state = "Resume"
local part = list:build({ desktop = desktop, source = { id = "local" }, plugin = desktop.plugin }, {
    width = 600,
    height = 404,
    desktop = desktop,
    y = 40,
})
Assert.eq(part:getSize().h, 404)
Assert.len(covers, 5)
Assert.eq(covers[1].w, 100)
Assert.is_true(covers[1].more)
Assert.eq(taps[1].w, 100)
Assert.eq(taps[1].h, 176)
Assert.is_nil(taps[1].on_hold)
local tap = taps[1].widget
tap:onTapBookInfo(nil, { pos = { x = 90, y = 140 } })
Assert.eq(opened_detail, books[1])
Assert.is_nil(opened_book)
Assert.eq(pager.page, 1)
Assert.eq(pager.pages, 1)
Assert.eq(texts[#texts], "最近阅读 · 5")
tap:onTapBookInfo(nil, { pos = { x = 50, y = 70 } })
Assert.eq(opened_book, books[1])
Assert.eq(covers[1].widget[1].kind, "opening")
Assert.eq(refresh_statuses[1], "running")
open_done(true)
Assert.eq(refresh_statuses[2], "idle")
Assert.is_nil(covers[1].widget[1])

List.saveRows(1)
List.saveCols(3)
covers = {}
list.page = 1
list:rebuild()
Assert.len(covers, 3)
Assert.eq(pager.page, 1)
Assert.eq(pager.pages, 2)
covers = {}
dirty = 0
pager.handlers.on_next()
Assert.eq(list.page, 2)
Assert.eq(view_updates, 0)
Assert.eq(dirty, 1)
Assert.len(covers, 2)
Assert.eq(pager.page, 2)
list:onEvent("source_changed")
Assert.eq(list.page, 1)

local pauses = 0
list.content_widget = { handleEvent = function(_, event)
    Assert.eq(event.handler, "onHomePause")
    pauses = pauses + 1
end }
list:onPause()
list:onDestroy()
Assert.eq(pauses, 1)
Assert.is_nil(list.widget)

List.saveRows(2)
List.saveCols(4)
shown = nil
events = {}
List:showSettings(desktop)
Assert.eq(shown.title, "最近阅读列表")
Assert.eq(shown.buttons[1][1].text, "一行")
Assert.eq(shown.buttons[1][2].text, "✓ 两行")
Assert.eq(shown.buttons[2][1].text, "每行 4 本")
Assert.eq(shown.buttons[3][1].text, "✓ 显示标题")
shown.buttons[1][1].callback()
Assert.eq(List.rows(), 1)
Assert.eq(events[1], "home_refresh")

shown = nil
List:showSettings(desktop)
Assert.eq(shown.buttons[1][1].text, "✓ 一行")
shown.buttons[3][1].callback()
Assert.eq(List.showTitle(), false)
Assert.eq(events[2], "home_refresh")
List.saveShowTitle(true)

shown = nil
List:showSettings(desktop)
shown.buttons[2][1].callback()
Assert.eq(shown.title_text, "每行数量")
Assert.eq(shown.value, 4)
Assert.eq(shown.value_min, 3)
Assert.eq(shown.value_max, 8)
shown.callback({ value = 5 })
Assert.eq(List.cols(), 5)
Assert.eq(events[3], "home_refresh")

List.saveRows(2)
List.saveCols(4)
List.saveShowTitle(false)
texts = {}
covers = {}
taps = {}
range = list:heightRange({}, { width = 600 })
Assert.eq(range.height, 352)
local untitled = List:new()
untitled.lifecycle.state = "Resume"
untitled:build({ desktop = desktop, source = { id = "local" } }, {
    width = 600,
    height = 352,
    desktop = desktop,
    y = 40,
})
Assert.len(covers, 5)
Assert.eq(taps[1].h, 150)
Assert.eq(texts[1], "最近阅读 · 5")
Assert.len(texts, 1)
List.saveShowTitle(true)

-- 分配高度不够两行时必须压封面，不能按完整格子往屏幕外画。
List.saveRows(2)
List.saveCols(4)
covers = {}
local squeezed = List:new()
squeezed.lifecycle.state = "Resume"
squeezed:build({ desktop = desktop, source = { id = "local" } }, {
    width = 600,
    height = 100,
    desktop = desktop,
    y = 40,
})
Assert.is_true(covers[1].h <= 50)
Assert.is_true(covers[1].w >= 1)

return true
