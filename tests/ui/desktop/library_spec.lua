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
local dialogs = {}
package.preload["ui/widget/progressbardialog"] = function()
    return {
        new = function(_, opts)
            opts.shown, opts.progress = false, 0
            function opts:show() self.shown = true end
            function opts:reportProgress(p) self.progress = p end
            -- 真实 ProgressbarDialog 在 onCloseWidget 里调 dismiss_callback。
            function opts:close()
                self.shown = false
                if self.dismiss_callback then self.dismiss_callback(); self.dismiss_callback = nil end
            end
            dialogs[#dialogs + 1] = opts
            return opts
        end,
    }
end

local scheduled, dirty = {}, {}
package.preload["ui/uimanager"] = function()
    return {
        show = function() end,
        nextTick = function(_, cb) cb() end,
        setDirty = function(_, _, mode, region) dirty[#dirty + 1] = { mode = mode, region = region } end,
        scheduleIn = function(_, _, cb) scheduled[#scheduled + 1] = cb end,
        unschedule = function(_, cb)
            for i = #scheduled, 1, -1 do if scheduled[i] == cb then table.remove(scheduled, i) end end
        end,
    }
end
--- 跑掉当前排队的定时器（跑的过程中新排的留到下一轮）。
local function runScheduled()
    local due = scheduled
    scheduled = {}
    for _, cb in ipairs(due) do cb() end
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
local labels = {}
package.preload["ui.components.icon"] = function()
    return {
        label = function(opts)
            labels[#labels + 1] = opts.text
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
local opened_origin
package.preload["ui.desktop.detail"] = function()
    return { open = function(_, origin, book) opened_origin, opened_detail = origin, book end }
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
    lifecycle = { state = "Create" },
    contentHeight = function() return 200 end,
    updateView = function() view_updates = view_updates + 1 end,
}
desktop.onEvent = function(_, event, value)
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
Assert.eq(opened_origin, "library")
Assert.eq(opened_detail, book)
Assert.is_nil(opened_book)
tap_widget:onTapBookInfo(nil, { pos = { x = 20, y = 20 } })
Assert.eq(opened_book, book)
Assert.eq(type(open_done), "function")
open_done(true)

-- 书城：无右下角更多；点封面交给调用方 on_open，不直接打开书。
opened_detail, opened_origin, opened_book, more_option = nil, nil, nil, nil
local store_opened
library:build(ctx, { books = { book } }, {
    page = 1, pages = 1, total = 1, show_status = false, search_only = true,
    on_open = function(b) store_opened = b end,
})
Assert.is_false(more_option)
tap_widget:onTapBookInfo(nil, { pos = { x = 20, y = 20 } })
Assert.eq(store_opened, book)
Assert.is_nil(opened_detail)
Assert.is_nil(opened_book)
Assert.not_nil(library:build(ctx, { books = { book } }, {
    page = 1, pages = 1, total = 1, show_status = false, search_only = true,
    on_open = function() end, on_back = function() end,
}))

library.state = nil
library:fetch()
Assert.eq(requested.search, "书")
Assert.eq(requested.sort, "recent_added")

library.filter = { search = "书", category = "科幻", series = "系列一", read_status = "unread", downloaded = true }
library.state = nil
library:fetch()
Assert.eq(requested.search, "书")
Assert.eq(requested.category, "科幻")
Assert.eq(requested.series, "系列一")
Assert.eq(requested.read_status, "unread")
Assert.is_true(requested.downloaded)
Assert.eq(requested.sort, "recent_added")

-- 桌面已销毁：updateView 排队的补拉不能再发请求。
requested = nil
library.state = nil
desktop.lifecycle.state = "Destroy"
library:updateView()
Assert.is_nil(requested)
desktop.lifecycle.state = "Create"

-- 手动刷新：同步在飞期间弹出假进度弹窗，不动图书馆页面；同步落下自动关窗。
source.syncBooksAsync = function() end
local emitted = 0
desktop.plugin.emitToSource = function(_, event, payload)
    Assert.eq(event, "library_refresh_request")
    emitted = emitted + 1
    payload._books_sync_pending = true
end
desktop.updateView = function() view_updates = view_updates + 1 end
view_updates = 0
library:rescan()
Assert.eq(emitted, 1)
Assert.len(dialogs, 1)
local dialog = dialogs[1]
Assert.is_true(dialog.shown)
Assert.eq(dialog.title, "正在刷新书库…")
Assert.eq(dialog.progress_max, 100)

library:rescan()
Assert.eq(emitted, 1, "刷新中重复点击忽略")
Assert.len(dialogs, 1)

runScheduled()
runScheduled()
Assert.eq(dialog.progress, 100 * Library.refreshPercentage(2))
Assert.is_true(dialog.progress > 20 and dialog.progress < 90)
Assert.eq(view_updates, 0, "进度跳动不重建页面")
Assert.is_true(Library.refreshPercentage(1000) <= 0.9, "永不走满")

-- 同步落下：下一跳关窗、停定时器。
desktop._books_sync_pending = false
runScheduled()
Assert.is_false(dialog.shown)
Assert.is_nil(library._refresh)
Assert.len(scheduled, 0)

-- 用户点按收起弹窗：定时器停，同步不受影响，之后可以再点刷新。
library:rescan()
dialog = dialogs[#dialogs]
dialog:close()
Assert.is_nil(library._refresh)
Assert.len(scheduled, 0)
Assert.is_true(desktop._books_sync_pending)
desktop._books_sync_pending = false

-- 源没开跑（本地源未配置目录，只弹引导）：不弹进度。
local count = #dialogs
desktop.plugin.emitToSource = function() emitted = emitted + 1 end
library:rescan()
Assert.is_nil(library._refresh)
Assert.len(dialogs, count)
Assert.len(scheduled, 0)

-- 切走/暂停：关窗。
desktop.plugin.emitToSource = function(_, _, payload) payload._books_sync_pending = true end
library:rescan()
dialog = dialogs[#dialogs]
library:onPause()
Assert.is_false(dialog.shown)
Assert.is_nil(library._refresh)
Assert.len(scheduled, 0)
desktop._books_sync_pending = false

package.loaded["ui.desktop.library"] = nil
