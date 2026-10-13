--[[--
desktop.pages.library：分组页签 / 工具条 / 网格与列表 / 分组列表下钻；书城复用的 build；
排序筛选下拉、搜索框、请求参数；手动刷新请求与下载标记校验。

@module tests.desktop.pages.library_spec
--]]
---@diagnostic disable: undefined-field

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")
local Themed = require("support.theme_stubs")
Themed.install()

local Container = require("ui/widget/container/widgetcontainer")
local Geom = require("ui/geometry")

-- 网格度量：一列 40 宽、封面 40×60，单元高 86。
local more_option
local tappables = {}
package.preload["ui.widgets.book"] = function()
    local function box(w, h) return Container:new{ dimen = Geom:new{ w = w, h = h } } end
    return {
        title = function(book) return book.title end,
        author = function(book) return book.authors or "" end,
        pct = function(book) return book.percent or 0 end,
        isRead = function(book) return book.read_state == 1 end,
        captionExtra = function() return 26 end,
        cover = function(_, _, _, cw, ch) return box(cw, ch), cw, ch end,
        tappable = function(w, h, on_tap)
            tappables[#tappables + 1] = on_tap
            return box(w, h)
        end,
        widget = function(_, _, book, cw, ch, opts)
            more_option = opts.more
            local Text = require("ui.themes.widgets.text")
            local VerticalGroup = require("ui/widget/verticalgroup")
            local cover = box(cw, ch)
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
package.preload["desktop.open"] = function()
    return { book = function(_, book, done) opened_book, open_done = book, done end }
end
local requested ---@type table
local listed_source_id
local filters_data = {
    read_counts = { { status = "unread", count = 1 } },
    downloaded_count = 0,
    author_counts = { { authors = "刘慈欣", count = 2 }, { authors = "", count = 1 } },
}
local catalog = {
    libraryScope = function(id) return { id, "extra" } end,
    filtersAsync = function(_, cb) cb({ data = filters_data }) end,
    groupCountsAsync = function(_, column, cb)
        Assert.eq(column, "authors")
        cb(filters_data.author_counts)
        return { cancel = function() end }
    end,
    listLibraryAsync = function(source_id, opts, cb)
        listed_source_id, requested = source_id, opts
        cb({ data = {}, count = 0 })
        return { cancel = function() end }
    end,
}
package.preload["book.catalog"] = function() return catalog end
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
        save = function(_, values) display = values end,
    }
end

local CoverCell = require("ui.widgets.cover")
CoverCell.denseCoverMetrics = function() return 40, 40, 60, 1, 0, 0, 86 end
local Library = require("desktop.pages.library")

local view_updates = 0
local source = { id = "moon" }
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
local book = { source_id = "moon", stable_id = "b1", title = "书一", read_state = 0, percent = 42, downloaded = true }

local function button(page, key)
    for _idx, b in ipairs(Kit.buttons(page)) do
        if b.icon == key or b.text == key then return b end
    end
    error("no button: " .. key)
end

local function tapText(page, text)
    for _idx, tap in ipairs(Kit.taps(page)) do
        for _idx2, s in ipairs(Kit.texts(tap)) do
            if s == text then return tap:onTapThemeArea(nil, Kit.tap(0, 0)) end
        end
    end
    error("no tap: " .. text)
end

local function render(books, total)
    library.state, library.total = { books = books }, total or #books
    library.page_size = library:metrics().page_size
    local page = library:buildPage(ctx)
    page:paintTo(Kit.canvas(), 0, 0)
    return page
end

-- 书城：上级 / 搜索 / 清除 + 共 N，网格无「更多」，整卡交给 on_open；整页正好是内容区尺寸。
local store_opened, back, searched = nil, 0, 0
local page = library:build(ctx, { books = { book } }, {
    page = 1, pages = 3, total = 7, show_status = false,
    on_open = function(b) store_opened = b end,
    on_back = function() back = back + 1 end,
    on_search = function() searched = searched + 1 end,
    on_clear = function() end,
})
Assert.eq(page:getSize().w, 600)
Assert.eq(page:getSize().h, 600)
local texts = Kit.texts(page)
for _idx, label in ipairs({ "上级", "搜索", "清除", "共7", "书一", "1 / 3" }) do
    Assert.contains(texts, label)
end
Assert.is_false(more_option)
page:paintTo(Kit.canvas(), 0, 0)
tapText(page, "书一")
Assert.eq(store_opened, book)
Assert.is_nil(opened_book)
button(page, "arrow_back"):onTapThemeButton()
button(page, "search"):onTapThemeButton()
Assert.eq(back, 1)
Assert.eq(searched, 1)
Assert.contains(Kit.texts(library:build(ctx, {}, {})), "加载中…")
Assert.contains(Kit.texts(library:build(ctx, { books = {} }, {})), "没有书籍")
Assert.contains(Kit.texts(library:build(ctx, { books = {}, err = "断网" }, {})), "断网")
Assert.contains(Kit.texts(library:build(ctx, { books = {} }, { empty_text = "没结果" })), "没结果")

-- 图书馆默认：书籍页签 + 网格；工具条显示总数、排序、状态，整页同样铺满。
Assert.eq(library.view, "grid")
page = render({ book }, 7)
Assert.eq(page:getSize().h, 600)
texts = Kit.texts(page)
for _idx, label in ipairs({ "书籍", "作者", "系列", "分类", "7 本书", "最近添加", "全部", "书一", "view_list" }) do
    Assert.contains(texts, label)
end
Assert.eq(type(more_option), "function")

-- 网格：右下角「更多」进详情，点卡片开书；开书期间封面盖「正在打开」条。
more_option()
Assert.eq(opened_origin, "library")
Assert.eq(opened_detail, book)
tapText(page, "书一")
Assert.eq(opened_book, book)
Assert.eq(library._opening_bar.kind, "opening")
open_done(true)
Assert.is_nil(library._opening_bar)

-- 切到列表：落盘，行内有书名、作者回退、进度百分比、已下载与竖向更多。
view_updates = 0
button(page, "view_list"):onTapThemeButton()
Assert.eq(library.view, "list")
Assert.eq(display.library_view, "list")
Assert.eq(view_updates, 1)
page = render({ book, { source_id = "moon", stable_id = "b2", title = "书二", read_state = 1 },
    { source_id = "moon", stable_id = "b3", title = "书三", authors = "某人", read_state = 0 } })
Assert.eq(page:getSize().h, 600)
texts = Kit.texts(page)
for _idx, label in ipairs({ "书一", "未知作者", "42%", "已下载", "more_vert", "书二", "已读完", "书三", "某人", "未读", "grid_view" }) do
    Assert.contains(texts, label)
end
for _idx, s in ipairs(texts) do Assert.is_true(s ~= "0%", "未读不画百分比") end
local list_m = Library.listMetrics(600, 600)
Assert.is_true(list_m.rows >= 1)
Assert.eq(list_m.page_size, list_m.rows)

-- 列表行：⋮ 进详情，整行开书。
opened_detail, opened_book = nil, nil
tappables[#tappables - 2]()
Assert.eq(opened_detail, book)
tapText(page, "书一")
Assert.eq(opened_book, book)
open_done(true)

-- 切回网格时停在原第一本书所在页。
library.page, library.page_size, library.total = 3, 2, 20
button(page, "grid_view"):onTapThemeButton()
Assert.eq(library.view, "grid")
Assert.eq(library.page, math.floor(4 / library.page_size) + 1, "第 3 页首本是第 5 本")
Assert.eq(library.page_size, Library.gridMetrics(600, 600, Library.tabsHeight()).page_size)

-- 排序下拉：落盘、回第一页。
page = render({ book }, 7)
library.page = 3
button(page, "最近添加"):onTapThemeButton()
Themed.choose(Themed.last("list"), 4)
Assert.eq(library.sort, "author")
Assert.eq(display.library_sort, "author")
Assert.eq(library.page, 1)

-- 状态下拉：拿到计数后弹出，点选写筛选、回第一页。
library.page = 2
button(page, "全部"):onTapThemeButton()
local menu = Themed.last("list")
Assert.eq(menu.items[2].text, "未读（1）")
Themed.choose(menu, 2)
Assert.eq(library.filter.read_status, "unread")
Assert.eq(library.page, 1)
catalog.filtersAsync = function(_, cb) cb(nil, "离线") end
local menus = #Themed.all("list")
button(page, "全部"):onTapThemeButton()
Assert.eq(#Themed.all("list"), menus, "取计数失败不弹下拉")
Assert.eq(Themed.last("toast").text, "离线")
catalog.filtersAsync = function(_, cb) cb({ data = filters_data }) end

-- 作者页签：分组列表按名称，空桶显示「未知作者」，点进一组按作者查书。
library.filter = {}
tapText(page, "作者")
Assert.eq(library.group, "author")
Assert.is_true(library:inGroupList())
library:updateView()
Assert.eq(#library.groups.rows, 2)
page = library:buildPage(ctx)
page:paintTo(Kit.canvas(), 0, 0)
texts = Kit.texts(page)
for _idx, label in ipairs({ "刘慈欣", "2 本书", "未知作者", "1 本书", "共2" }) do
    Assert.contains(texts, label)
end
for _idx, s in ipairs(texts) do Assert.is_true(s ~= "sort", "分组列表没有排序下拉") end
tapText(page, "刘慈欣")
Assert.eq(library.filter.author, "刘慈欣")
Assert.is_false(library:inGroupList())
library:fetch()
Assert.eq(requested.author, "刘慈欣")
Assert.is_false(requested.unauthor)
page = render({ book }, 2)
texts = Kit.texts(page)
Assert.contains(texts, "刘慈欣")
button(page, "arrow_back"):onTapThemeButton()
Assert.is_nil(library.filter.author)
Assert.is_true(library:inGroupList())
library:openGroup("")
Assert.is_true(library.filter.unauthor)
library:fetch()
Assert.is_true(requested.unauthor)
Assert.eq(requested.author, "")

-- 分组列表本地翻页：滑动只动 group_page，不发请求。
library:closeGroup()
library.groups = { rows = {} }
for i = 1, 40 do library.groups.rows[i] = { value = "作者" .. i, count = 1 } end
requested = nil
library:onEvent("swipe", { direction = "west" })
Assert.eq(library.group_page, 2)
Assert.is_nil(requested)
library:onEvent("swipe", { direction = "east" })
library:onEvent("swipe", { direction = "east" })
Assert.eq(library.group_page, 1, "第一页不再往前")

-- 换页签丢下钻条件；搜索回到书籍页签。
library.filter = { author = "刘慈欣", read_status = "unread" }
library:selectGroup("series")
Assert.is_nil(library.filter.author)
Assert.eq(library.filter.read_status, "unread")
Assert.is_nil(library.groups)
library:showSearch()
local input = Themed.last("input")
input.callback("三体")
Assert.eq(library.group, "books")
Assert.eq(library.filter.search, "三体")
Assert.eq(library.page, 1)
page = render({ book }, 1)
button(page, "search_off"):onTapThemeButton()
Assert.is_nil(library.filter.search)
local custom
library:showSearch(function(q) custom = q end, "初始")
Assert.eq(Themed.last("input").fields[1].text, "初始")
Themed.last("input").callback("x")
Assert.eq(custom, "x")

-- 请求参数：搜索、筛选、排序全部透传。
library.filter = { search = "书", category = "科幻", series = "系列一", read_status = "unread", downloaded = true }
library:fetch()
Assert.eq(listed_source_id, "moon")
Assert.eq(requested.search, "书")
Assert.eq(requested.category, "科幻")
Assert.eq(requested.series, "系列一")
Assert.eq(requested.read_status, "unread")
Assert.is_true(requested.downloaded)
Assert.eq(requested.sort, "author")

-- 书架变化：只作废缓存，不动页码（越界由 fetch 钳回）。
library.state, library.groups = { books = {} }, { rows = {} }
library.page = 3
library:onEvent("shelf_changed")
Assert.is_nil(library.state)
Assert.is_nil(library.groups)
Assert.eq(library.page, 3)
local real_list = catalog.listLibraryAsync
local pages_asked = {}
catalog.listLibraryAsync = function(_, opts, cb)
    pages_asked[#pages_asked + 1] = opts.page
    cb({ data = {}, count = 1 })
    return { cancel = function() end }
end
library.page = 5
library:fetch()
Assert.eq(library.page, 1)
Assert.eq(pages_asked[1], 5)
Assert.eq(pages_asked[2], 1)
catalog.listLibraryAsync = real_list

-- 换源：清筛选与缓存，页签和视图保留。
library.group, library.filter = "author", { author = "x" }
library:onEvent("source_changed")
Assert.eq(library.group, "author")
Assert.eq(next(library.filter), nil)
Assert.is_nil(library.groups)
library.group = "books"

-- 桌面已销毁：updateView 排队的补拉不能再发请求。
requested = nil
library.state = nil
desktop.closed = true
library:updateView()
Assert.is_nil(requested)
desktop.closed = nil

-- 手动刷新：交给 desktop.sync（进度弹窗归任务队列，由它前台跟随），自己不弹窗。
source.syncBooksAsync = function() end
local emitted = 0
package.loaded["desktop.sync"] = {
    refresh = function(desk)
        Assert.eq(desk, desktop)
        emitted = emitted + 1
    end,
}
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
