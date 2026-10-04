--[[--
desktop.pages.library：主题工具栏 / 网格 / 翻页；封面点开书、右下角进详情；筛选排序参数；
搜索框；手动刷新请求与下载标记校验。

@module tests.desktop.pages.library_spec
--]]

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")
local Themed = require("support.theme_stubs")
Themed.install()

local Container = require("ui/widget/container/widgetcontainer")
local Geom = require("ui/geometry")

-- 网格度量：一列 40 宽、封面 40×60，单元高 86。
local more_option
package.preload["ui.widgets.book"] = function()
    return {
        title = function(book) return book.title end,
        widget = function(_, _, book, cw, ch, opts)
            more_option = opts.more
            local Text = require("ui.themes.widgets.text")
            local VerticalGroup = require("ui/widget/verticalgroup")
            local cover = Container:new{ dimen = Geom:new{ w = cw, h = ch } }
            local kids = { cover }
            if opts.show_title ~= false then
                kids[#kids + 1] = Text.line("caption", book.title or "", { width = opts.slot_w or cw })
            end
            return VerticalGroup:new(kids), ch, cover
        end,
        openingBar = function() return Container:new{ dimen = Geom:new{ w = 1, h = 1 }, kind = "opening" } end,
    }
end
local opened_detail, opened_origin
package.preload["desktop.detail"] = function()
    return { open = function(_, origin, book) opened_origin, opened_detail = origin, book end }
end
local opened_book, open_done
package.preload["book.open"] = function()
    return { book = function(_, book, done) opened_book, open_done = book, done end }
end
package.preload["book.catalog"] = function()
    return { libraryScope = function(id) return { id, "extra" } end }
end
local verifies = {}
package.preload["book.store"] = function()
    return {
        verifyDownloadsAsync = function(scope, cb)
            verifies[#verifies + 1] = { scope = scope, cb = cb }
            return { cancel = function() end }
        end,
    }
end
local display = Kit.display
display.library_sort = "recent_added"
package.preload["utils.settings"] = function()
    return {
        get = function() return display end,
        saveSection = function(_, values) display = values end,
    }
end

local CoverCell = require("ui.widgets.cover")
CoverCell.denseCoverMetrics = function() return 40, 40, 60, 1, 0, 0, 86 end
local Library = require("desktop.pages.library")

local view_updates = 0
local requested
local source = {
    id = "moon",
    filtersAsync = function(_, cb) cb({ data = {} }) end,
    listLibraryAsync = function(_, opts, cb)
        requested = opts
        cb({ data = {}, count = 0 })
        return { cancel = function() end }
    end,
}
local desktop = {
    plugin = {},
    dimen = { w = 600 },
    tab = "library",
    source = source,
    source_generation = 0,
    contentHeight = function() return 600 end,
    updateView = function() view_updates = view_updates + 1 end,
}
local library = Library:new{ desktop = desktop }
desktop.library = library
local ctx = { width = 600, height = 600, desktop = desktop, source = source, plugin = desktop.plugin }
desktop.ctx = function() return ctx end
local book = { source_id = "moon", stable_id = "b1", title = "书一", read_state = 0 }

-- 工具栏、共 N、网格铺满、翻页条；整页正好是内容区尺寸。
local page = library:build(ctx, { books = { book } }, { page = 1, pages = 3, total = 7 })
Assert.eq(page:getSize().w, 600)
Assert.eq(page:getSize().h, 600)
local texts = Kit.texts(page)
for _, label in ipairs({ "刷新", "筛选", "搜索", "清除", "共7", "书一", "1 / 3" }) do
    Assert.contains(texts, label)
end
Assert.is_true(more_option)

-- 点封面右下角进详情，其余位置开书；开书期间封面盖「正在打开」条。
page:paintTo(Kit.canvas(), 0, 0)
local cell = Kit.taps(page)[1]
local d = cell.dimen
cell:onTapThemeArea(nil, { pos = { x = d.x + 40 - 5, y = d.y + 60 - 5 } })
Assert.eq(opened_origin, "library")
Assert.eq(opened_detail, book)
Assert.is_nil(opened_book)
cell:onTapThemeArea(nil, { pos = { x = d.x + 5, y = d.y + 5 } })
Assert.eq(opened_book, book)
Assert.eq(library._opening_bar.kind, "opening")
open_done(true)
Assert.is_nil(library._opening_bar)

-- 翻页条接到 gotoPage。
local nexts = {}
page = library:build(ctx, { books = { book } }, {
    page = 1, pages = 3, on_next = function() nexts[#nexts + 1] = true end,
})
local buttons = Kit.buttons(page)
buttons[#buttons]:onTapThemeButton()
Assert.len(nexts, 1)

-- 书城：只有搜索/清除（+上级），无右下角「更多」，点封面交给 on_open。
opened_detail, opened_book = nil, nil
local store_opened, back = nil, 0
page = library:build(ctx, { books = { book } }, {
    page = 1, pages = 1, total = 1, show_status = false, search_only = true,
    on_open = function(b) store_opened = b end, on_back = function() back = back + 1 end,
})
Assert.is_false(more_option)
texts = Kit.texts(page)
Assert.contains(texts, "上级")
for _, s in ipairs(texts) do Assert.is_true(s ~= "刷新" and s ~= "筛选", "书城不出刷新/筛选") end
page:paintTo(Kit.canvas(), 0, 0)
cell = Kit.taps(page)[1]
cell:onTapThemeArea(nil, { pos = { x = cell.dimen.x + 35, y = cell.dimen.y + 55 } })
Assert.eq(store_opened, book)
Assert.is_nil(opened_detail)
Kit.buttons(page)[1]:onTapThemeButton()
Assert.eq(back, 1)

-- 空态 / 加载中 / 错误。
Assert.contains(Kit.texts(library:build(ctx, {}, {})), "加载中…")
Assert.contains(Kit.texts(library:build(ctx, { books = {} }, {})), "没有书籍")
Assert.contains(Kit.texts(library:build(ctx, { books = {}, err = "断网" }, {})), "断网")

-- 请求参数：搜索、筛选、排序全部透传。
library.filter = { search = "书" }
library:fetch()
Assert.eq(requested.search, "书")
Assert.eq(requested.sort, "recent_added")
library.filter = { search = "书", category = "科幻", series = "系列一", read_status = "unread", downloaded = true }
library:fetch()
Assert.eq(requested.category, "科幻")
Assert.eq(requested.series, "系列一")
Assert.eq(requested.read_status, "unread")
Assert.is_true(requested.downloaded)

-- 筛选回调：写筛选与排序、落盘、回第一页。
local Filter = require("desktop.pages.library.filter")
local filter_opts
local real_open = Filter.open
Filter.open = function(opts) filter_opts = opts end
library.page = 3
library:showFilter()
filter_opts.on_apply({ category = "科幻" }, "author")
Assert.eq(library.filter.category, "科幻")
Assert.eq(library.sort, "author")
Assert.eq(display.library_sort, "author")
Assert.eq(library.page, 1)
Filter.open = real_open

-- 搜索框：主题 Input，确定即应用（空串等同清除）。
library.filter = { search = "旧" }
library:showSearch()
local input = Themed.last("input")
Assert.eq(input.fields[1].text, "旧")
input.callback("三体")
Assert.eq(library.filter.search, "三体")
Assert.eq(library.page, 1)
input.callback("")
Assert.is_nil(library.filter.search)
local custom
library:showSearch(function(q) custom = q end, "初始")
Assert.eq(Themed.last("input").fields[1].text, "初始")
Themed.last("input").callback("x")
Assert.eq(custom, "x")

-- 桌面已销毁：updateView 排队的补拉不能再发请求。
requested = nil
library.state = nil
desktop.closed = true
library:updateView()
Assert.is_nil(requested)
desktop.closed = nil

-- 手动刷新：只向源发刷新请求（进度弹窗归任务队列，由源前台跟随），自己不弹窗。
source.syncBooksAsync = function() end
local emitted = 0
source.onEvent = function(_, event, payload)
    Assert.eq(event, "library_refresh_request")
    Assert.eq(payload, desktop)
    emitted = emitted + 1
end
view_updates = 0
library:rescan()
Assert.eq(emitted, 1)
Assert.len(Themed.all("progress_dialog"), 0)

-- 刷新同时后台校验已下载标记：范围跟书库一致；在飞时不重复起。
Assert.len(verifies, 1)
Assert.eq(verifies[1].scope[1], "moon")
Assert.eq(verifies[1].scope[2], "extra")
library:verifyDownloads()
Assert.len(verifies, 1, "校验在飞不重复起")
view_updates = 0
library.state = { books = {} }
verifies[1].cb(0)
Assert.eq(view_updates, 0, "没撤掉登记不重建")
Assert.not_nil(library.state)
library:verifyDownloads()
desktop.tab = "home"
verifies[2].cb(3)
Assert.eq(view_updates, 0, "已离开图书馆不重建")
desktop.tab = "library"
library:verifyDownloads()
verifies[3].cb(2)
Assert.is_nil(library.state, "撤掉登记后重拉当前页")
Assert.eq(view_updates, 1)

-- 源不支持同步：不发请求。
source.syncBooksAsync = nil
library:rescan()
Assert.eq(emitted, 1)
