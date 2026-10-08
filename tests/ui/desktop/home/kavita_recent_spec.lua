--[[-- Kavita 最近阅读：服务端 On Deck，封面网格，只显示 epub/pdf。 --]]

local Assert = require("support.assert")

local texts = {}
local taps = {}
local covers = {}
local pager
local shown
local dirty = 0
local home = {
    home_kavita_recent_rows = 2,
    home_kavita_recent_cols = 4,
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
local opened_book
local open_done
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
            local cover_widget = {}
            covers[#covers + 1] = { book = book, w = w, h = h, more = opts and opts.more, widget = cover_widget }
            return cover_widget
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
        show = function(_, widget_shown) shown = widget_shown end,
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

local on_deck_books = {}
local on_deck_calls = 0
local on_deck_err
package.preload["source.registry"] = function()
    return {
        resolve = function(id)
            return {
                id = id,
                onDeckAsync = function(_, cb)
                    on_deck_calls = on_deck_calls + 1
                    cb(on_deck_books, on_deck_err)
                    return { cancel = function() end }
                end,
            }
        end,
    }
end

local View = require("ui.desktop.home.views.kavita_recent")
Assert.eq(View.id, "kavita_recent")
Assert.eq(View.label, "Kavita 最近阅读")
Assert.eq(View.rows(), 2)
Assert.eq(View.cols(), 4)
Assert.eq(View.showTitle(), true)
View.saveShowTitle(false)
Assert.eq(View.showTitle(), false)
View.saveShowTitle(true)
View.saveCols(2)
Assert.eq(View.cols(), 3)
View.saveCols(9)
Assert.eq(View.cols(), 8)
View.saveCols(4)
View.saveRows(0)
Assert.eq(View.rows(), 2)

local list = View:new()
local range = list:heightRange({}, { width = 600 })
Assert.eq(range.height, 404)
Assert.is_nil(range.fill)

local events = {}
local desktop = {
    plugin = {},
    onEvent = function(_, event, payload)
        events[#events + 1] = event
    end,
}

list.lifecycle.state = "Resume"
list:build({ desktop = desktop, source = { id = "local" }, plugin = desktop.plugin }, {
    width = 600,
    height = 404,
    desktop = desktop,
    y = 40,
})
Assert.len(covers, 0)
-- 数据未到达（data 为 nil）时显示加载态，不误报空书架。
Assert.eq(texts[1], "加载中…")
Assert.eq(pager.pages, 1)

-- 服务端返回后重建网格；EPUB/PDF 各一。
on_deck_books = {
    { source_id = "kavita", stable_id = "1", title = "book1", format = "epub", percent = 25 },
    { source_id = "kavita", stable_id = "2", title = "book2", format = "pdf", percent = 0 },
}
texts = {}
list:onResume()
Assert.eq(on_deck_calls, 1)
Assert.len(covers, 2)
Assert.eq(covers[1].book.stable_id, "1")
Assert.eq(texts[#texts], "Kavita 最近阅读 · 2")
Assert.eq(pager.page, 1)
Assert.eq(pager.pages, 1)

-- 空结果回落到空态。
on_deck_books = {}
texts = {}
list:onResume()
Assert.eq(on_deck_calls, 2)
Assert.eq(texts[1], "没有在读的书")
Assert.eq(texts[#texts], "Kavita 最近阅读")

-- 失败且无旧数据时显示错误文案。
on_deck_books = nil
on_deck_err = "未配置服务器地址或 API Key"
local empty = View:new()
empty.lifecycle.state = "Resume"
texts = {}
empty:build({ desktop = desktop, source = { id = "local" } }, {
    width = 600,
    height = 404,
    desktop = desktop,
    y = 40,
})
empty:onResume()
Assert.eq(texts[#texts - 1], "未配置服务器地址或 API Key")
Assert.eq(texts[#texts], "Kavita 最近阅读")

-- 设置对话框复用最近阅读列表的文案。
shown = nil
events = {}
View:showSettings(desktop)
Assert.eq(shown.title, "Kavita 最近阅读")
Assert.eq(shown.buttons[1][2].text, "✓ 两行")
Assert.eq(shown.buttons[2][1].text, "每行 4 本")
shown.buttons[1][1].callback()
Assert.eq(View.rows(), 1)
Assert.eq(events[1], "home_refresh")
View.saveRows(2)

local pauses = 0
list.content_widget = { handleEvent = function(_, event)
    Assert.eq(event.handler, "onHomePause")
    pauses = pauses + 1
end }
list:onPause()
Assert.eq(pauses, 1)
Assert.is_nil(list.content_widget)

return true
