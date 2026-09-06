--[[-- ui.desktop.library：阅读状态筛选、长按标记与删除。 --]]

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

local shown
package.preload["ui/uimanager"] = function()
    return {
        show = function(_, widget) shown = widget end,
        nextTick = function(_, cb) cb() end,
    }
end
package.preload["ui/widget/confirmbox"] = widgetModule
package.preload["ui/widget/infomessage"] = widgetModule
package.preload["ffi/blitbuffer"] = function()
    return { COLOR_WHITE = 0, COLOR_BLACK = 1 }
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
        pill = function(child) return child end,
        card = function(child) return child end,
    }
end
package.preload["ui.components.pager"] = function()
    return {
        bandH = function() return 10 end,
        band = function() return { getSize = function() return { w = 100, h = 10 } end } end,
    }
end

local popup_sheet, popup_list
package.preload["ui.components.popup"] = function()
    return {
        sheet = function(opts) popup_sheet = opts return opts end,
        list = function(opts) popup_list = opts return opts end,
        setListItems = function(menu, title, items)
            menu.title = title
            menu.items = items
        end,
    }
end

local hold_callback
package.preload["ui.components.bookinfo"] = function()
    return {
        title = function(book) return book.title end,
        cover = function() return { getSize = function() return { w = 40, h = 60 } end } end,
        tappable = function(w, h, on_tap, on_hold)
            if on_hold then hold_callback = on_hold end
            return {
                dimen = { w = w, h = h },
                getSize = function(self) return self.dimen end,
                on_tap = on_tap,
            }
        end,
    }
end

local set_read
package.preload["db.book"] = function()
    return {
        setRead = function(source_id, stable_id, value)
            set_read = { source_id, stable_id, value }
            return true
        end,
    }
end
package.preload["utils.log"] = function()
    return { warn = function() end }
end
package.preload["gettext"] = function() return function(s) return s end end
local display = { library_view = "flat" }
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

local rebuilds = 0
local deleted
local requested
local source = {
    capabilities = function() return { search = true } end,
    filtersAsync = function(_, cb) cb({ data = { category = {}, series = {} } }) end,
    listLibraryAsync = function(_, opts, cb)
        requested = opts
        cb({ data = {}, count = 0 })
        return { cancel = function() end }
    end,
    deleteBookAsync = function(_, identity, cb)
        deleted = identity
        cb(true)
    end,
}
local desktop = {
    width = 100,
    height = 200,
    dimen = { w = 100 },
    tab = "library",
    page = 2,
    total = 1,
    filter = { search = "书" },
    source = source,
    source_generation = 0,
    contentHeight = function() return 200 end,
    rebuild = function() rebuilds = rebuilds + 1 end,
}
local ctx = {
    width = 100,
    height = 200,
    desktop = desktop,
    source = source,
}
desktop.ctx = function() return ctx end
local book = {
    source_id = "moon",
    stable_id = "b1",
    title = "书一",
    read_state = 0,
}

Library.build(ctx, { books = { book } }, { page = 1, pages = 1, total = 1 })
Assert.not_nil(hold_callback)
hold_callback()
Assert.eq(popup_sheet.items[1].text, "标记为已读")
popup_sheet.items[1].callback()
Assert.eq(set_read[1], "moon")
Assert.eq(set_read[2], "b1")
Assert.is_true(set_read[3])
Assert.eq(book.read_state, 1)
Assert.eq(rebuilds, 1)

hold_callback()
Assert.eq(popup_sheet.items[1].text, "标记为未读")
popup_sheet.items[2].callback()
Assert.eq(shown.text, "确定删除《书一》？")
shown.ok_callback()
Assert.eq(deleted.stable_id, "b1")
Assert.eq(deleted.source, source)
Assert.eq(desktop.page, 1)

Library.showViewPicker(desktop)
Assert.eq(popup_sheet.title, "图书馆视图")
Assert.eq(#popup_sheet.items, 4)
Assert.eq(popup_sheet.items[2].text, "分类视图")
Assert.eq(popup_sheet.items[3].text, "系列视图")
Assert.eq(popup_sheet.items[4].text, "阅读状态视图")

desktop._library_state = nil
Library.fetch(desktop)
Assert.eq(requested.search, "书")

Library.setView(desktop, "category")
Assert.eq(display.library_view, "category")
Assert.is_true(Library.isGroupIndex(desktop))
source.filtersAsync = function(_, cb)
    cb({ data = {
        category_counts = {
            { category = "科幻", count = 3 },
            { category = "", count = 2 },
            { category = "历史", count = 1 },
        },
        series_counts = { { series = "系列一", count = 6 } },
        read_counts = {
            { status = "new", count = 1 },
            { status = "read", count = 2 },
            { status = "unread", count = 3 },
        },
    } })
end
Library.fetchGroups(desktop)
Assert.eq(desktop._library_groups_state.groups[1].category, "科幻")
Assert.eq(desktop._library_groups_state.groups[2].count, 2)
Assert.not_nil(Library.page(desktop))
Assert.eq(Library.pages(desktop), 2)
Library.gotoPage(desktop, 2)
Assert.eq(desktop.page, 2)

Library.enterGroup(desktop, "")
Assert.is_false(Library.isGroupIndex(desktop))
Library.fetch(desktop)
Assert.is_true(requested.uncategorized)
Library.leaveGroup(desktop)
Assert.is_true(Library.isGroupIndex(desktop))

Library.setView(desktop, "series")
Library.fetchGroups(desktop)
Assert.eq(desktop._library_groups_state.groups[1].series, "系列一")
Library.enterGroup(desktop, "系列一")
Library.fetch(desktop)
Assert.eq(requested.series, "系列一")

Library.setView(desktop, "status")
Library.fetchGroups(desktop)
Assert.eq(#desktop._library_groups_state.groups, 3)
Library.enterGroup(desktop, "new")
Library.fetch(desktop)
Assert.eq(requested.read_status, "new")

package.loaded["ui.desktop.library"] = nil
