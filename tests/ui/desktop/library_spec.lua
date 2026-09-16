--[[-- ui.desktop.library：封面点开书、更多进详情、筛选排序。 --]]

local Assert = require("support.assert")

local function widgetModule()
    return {
        new = function(_, opts)
            opts.getSize = opts.getSize or function(self)
                return self.dimen or { w = 10, h = 10 }
            end
            return opts
        end,
    }
end
for _, name in ipairs({
    "ui/widget/container/centercontainer",
    "ui/widget/container/framecontainer",
    "ui/widget/inputdialog",
    "ui/widget/verticalgroup",
    "ui/widget/verticalspan",
    "ui/widget/horizontalgroup",
    "ui/widget/horizontalspan",
    "ui/widget/textwidget",
}) do
    package.preload[name] = widgetModule
end

package.preload["ui/uimanager"] = function()
    return {
        show = function() end,
        nextTick = function(_, cb) cb() end,
        setDirty = function() end,
    }
end
package.preload["ui/widget/confirmbox"] = widgetModule
package.preload["ui/widget/infomessage"] = widgetModule
package.preload["ffi/blitbuffer"] = function()
    return { COLOR_WHITE = 0, COLOR_BLACK = 1 }
end
package.preload["ui/geometry"] = function()
    return { new = function(_, opts) return opts end }
end
package.preload["device"] = function()
    return { screen = { getWidth = function() return 100 end } }
end
package.preload["ui.components.bookui"] = function()
    return {
        sz = function(v) return v end,
        face = function() return {} end,
        muted = function() return 0 end,
        surface = function() return 0 end,
        denseCoverMetrics = function()
            return 40, 40, 60, 1, 0, 0, 86
        end,
    }
end
package.preload["ui.components.icon"] = function()
    return {
        label = function()
            return { getSize = function() return { w = 10, h = 10 } end }
        end,
    }
end
package.preload["ui.components.surface"] = function()
    return {
        build = function(opts) return opts.child end,
    }
end
package.preload["ui.components.pager"] = function()
    return {
        bandH = function() return 10 end,
        band = function() return { getSize = function() return { w = 100, h = 10 } end } end,
    }
end

local tap_callback
local tap_widget
local more_option
local hold_callback
package.preload["ui.components.bookinfo"] = function()
    return {
        title = function(book) return book.title end,
        cover = function(_, _, _, _, _, opts)
            more_option = opts and opts.more
            return { getSize = function() return { w = 40, h = 60 } end }
        end,
        openingBar = function() return { kind = "opening" } end,
        tappable = function(w, h, on_tap, on_hold)
            tap_callback = on_tap
            hold_callback = on_hold
            tap_widget = {
                dimen = { x = 0, y = 0, w = w, h = h },
                getSize = function(self) return self.dimen end,
                on_tap = on_tap,
            }
            return tap_widget
        end,
    }
end

local opened_detail
package.preload["ui.desktop.detail"] = function()
    return { open = function(_, origin, book) opened_detail = book; Assert.eq(origin, "library") end }
end
local opened_book
local open_done
package.preload["book.open"] = function()
    return { book = function(_, book, done) opened_book, open_done = book, done end }
end
package.preload["utils.log"] = function()
    return { warn = function() end, dbg = function() end }
end
package.preload["gettext"] = function() return function(s) return s end end
local display = { library_sort = "recent_added" }
package.preload["utils.settings"] = function()
    return {
        get = function(section)
            if section == "display" then return display end
            return display
        end,
        saveSection = function(_, values) display = values end,
    }
end
package.preload["ffi/util"] = function()
    return {
        template = function(s, value)
            return s:gsub("%%1", tostring(value))
        end,
    }
end

package.loaded["ui.desktop.library"] = nil
local Library = require("ui.desktop.library")

local view_updates = 0
local requested
local source = {
    capabilities = function() return { search = true } end,
    filtersAsync = function(_, cb) cb({ data = { category = {}, series = {} } }) end,
    listLibraryAsync = function(_, opts, cb)
        requested = opts
        cb({ data = {}, count = 0 })
        return { cancel = function() end }
    end,
}
local desktop = {
    plugin = {},
    width = 100,
    height = 200,
    dimen = { w = 100 },
    tab = "library",
    source = source,
    source_generation = 0,
    contentHeight = function() return 200 end,
    updateView = function() view_updates = view_updates + 1 end,
}
local refresh_statuses = {}
desktop.onEvent = function(_, event, value)
    if event == "refresh_status" then refresh_statuses[#refresh_statuses + 1] = value end
end
local library = Library:new{ desktop = desktop, name = "library" }
Assert.eq(library.lifecycle.state, "new")
library:onCreate()
Assert.eq(library.lifecycle.state, "Create")
desktop.library = library
library.page = 2
library.total = 1
library.filter = { search = "书" }
local ctx = {
    width = 100,
    height = 200,
    desktop = desktop,
    source = source,
    plugin = desktop.plugin,
}
desktop.ctx = function() return ctx end
local book = {
    source_id = "moon",
    stable_id = "b1",
    title = "书一",
    read_state = 0,
}

library:build(ctx, { books = { book } }, { page = 1, pages = 1, total = 1 })
Assert.is_true(more_option)
Assert.not_nil(tap_callback)
Assert.is_nil(hold_callback)
tap_widget:onTapBookInfo(nil, { pos = { x = 35, y = 55 } })
Assert.eq(opened_detail, book)
Assert.is_nil(opened_book)
tap_widget:onTapBookInfo(nil, { pos = { x = 20, y = 20 } })
Assert.eq(opened_book, book)
Assert.eq(refresh_statuses[1], "running")
Assert.eq(type(open_done), "function")
open_done(true)
Assert.eq(refresh_statuses[2], "idle")

library.state = nil
library:fetch()
Assert.eq(requested.search, "书")
Assert.eq(requested.sort, "recent_added")

library.filter = { search = "书", category = "科幻", series = "系列一", read_status = "unread" }
library.state = nil
library:fetch()
Assert.eq(requested.search, "书")
Assert.eq(requested.category, "科幻")
Assert.eq(requested.series, "系列一")
Assert.eq(requested.read_status, "unread")
Assert.eq(requested.sort, "recent_added")

package.loaded["ui.desktop.library"] = nil
