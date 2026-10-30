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
local grid_opts
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
            more_option, grid_opts = opts.more, opts
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
-- 断网判定与「源是否声明书架缓存」两个触发条件（05 A4）。
local network, shelf_cache = { connected = true }, false
package.preload["ui/network/manager"] = function()
    return { isConnected = function() return network.connected end }
end
local filters_data = {
    read_counts = { { status = "unread", count = 1 } },
    downloaded_count = 0,
    author_counts = { { authors = "刘慈欣", count = 2 }, { authors = "", count = 1 } },
}
local catalog = {
    libraryScope = function(id) return { id, "extra" } end,
    hasShelfCache = function() return shelf_cache end,
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
display.library_title, display.library_author = true, false
display.library_style, display.library_tap = "kindle", "open"
display.library_random = true
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

-- 书城：上级 + 搜索图标（无清除）+ 共 N，网格无「更多」，整卡交给 on_open；整页正好是内容区尺寸。
local store_opened, back, searched = nil, 0, 0
local page = library:build(ctx, { books = { book } }, {
    page = 1, pages = 3, total = 7, show_status = false,
    on_open = function(b) store_opened = b end,
    on_back = function() back = back + 1 end,
    on_search = function() searched = searched + 1 end,
})
Assert.eq(page:getSize().w, 600)
Assert.eq(page:getSize().h, 600)
local texts = Kit.texts(page)
for _idx, label in ipairs({ "上级", "共7", "书一", "1 / 3" }) do
    Assert.contains(texts, label)
end
for _idx, s in ipairs(texts) do
    Assert.is_true(s ~= "搜索" and s ~= "清除", "书城工具条只留搜索图标：" .. s)
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

Kit.color_enabled = true
local colored_page = library:buildPage(ctx)
local accent = require("ui.themes").current().color.accent
Assert.eq(Kit.find(colored_page, function(w) return w.text == "书籍" end)[1].fgcolor, accent)
Assert.eq(Kit.find(colored_page, function(w) return w.text == "作者" end)[1].fgcolor,
    require("ui.themes").current().color.muted)
local underline = Kit.find(colored_page, function(w)
    return w.style and w.style.bg == accent and w.box_h == 2 and w.box_w == 150
end)[1]
Assert.is_true(underline ~= nil, "选中页签下划线与标题同色")
Assert.is_true(underline.keep_bg, "选中条是内容，壁纸不能挖掉")
local color_canvas = Kit.canvas()
underline:paintTo(color_canvas, 0, 0)
Assert.is_true(color_canvas.ops[1].rgb, "页签下划线实际保留 RGB")
Kit.color_enabled = false

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

-- 随机一本：有书才出骰子；按总数随机一页、每页一本，沿用当前筛选排序，取到即开书。
local dice_page = render({ book }, 0)
for _idx, b in ipairs(Kit.buttons(dice_page)) do Assert.is_false(b.icon == "casino", "空库不出骰子") end
library.filter, library.sort = { read_status = "unread", author = "刘慈欣" }, "title"
dice_page = render({ book }, 5)
local asked
catalog.listLibraryAsync = function(_, opts, cb)
    asked = opts
    cb({ data = { book }, count = 5 })
    return { cancel = function() end }
end
opened_book = nil
button(dice_page, "casino").callback()
Assert.eq(asked.page_size, 1)
Assert.is_true(asked.page >= 1 and asked.page <= 5)
Assert.eq(asked.read_status, "unread")
Assert.eq(asked.author, "刘慈欣")
Assert.eq(asked.sort, "title")
Assert.eq(opened_detail, book, "随机先开详情页")
Assert.is_nil(opened_book, "不直接开书")
Assert.is_nil(library.random_cancel)
catalog.listLibraryAsync = real_list

-- 筛选没限定阅读状态：按随机范围抽；范围内没有就提示，不退回已读。
library.filter = {}
dice_page = render({ book }, 5)
local asks = {}
local counts = { new = 3, unread = 0 }
catalog.listLibraryAsync = function(_, opts, cb)
    asks[#asks + 1] = { read_status = opts.read_status, page = opts.page }
    cb({ data = { book }, count = counts[opts.read_status] or 5 })
    return { cancel = function() end }
end
button(dice_page, "casino").callback()
Assert.eq(#asks, 2)
Assert.eq(asks[2].read_status, "new")
Assert.is_true(asks[2].page >= 1 and asks[2].page <= 3)
asks, counts.new = {}, 0
button(dice_page, "casino").callback()
Assert.eq(#asks, 1, "默认范围只问未读")
display.random_scope = "reading"
counts.unread = 2
asks = {}
button(dice_page, "casino").callback()
Assert.eq(asks[2].read_status, "unread", "含阅读中时再问阅读中")
display.random_scope = "new"
catalog.listLibraryAsync = real_list
display.library_random = false
for _idx, b in ipairs(Kit.buttons(render({ book }, 5))) do Assert.is_false(b.icon == "casino", "开关关闭不出骰子") end
display.library_random = true

do -- 页签按设置显示，书籍恒在；取消当前页签后落回书籍
    local function ids()
        local out = {}
        for _idx, g in ipairs(library:visibleTabs()) do out[#out + 1] = g.id end
        return table.concat(out, ",")
    end
    local saved = display.library_tabs
    display.library_tabs = { "books", "author", "series", "category", "folder" }
    Assert.eq(ids(), "books,author,series,category")
    display.library_tabs = { "category" }
    Assert.eq(ids(), "books,category")
    library.group = "series"
    library:normalizeGroup()
    Assert.eq(library.group, "books")
    display.library_tabs = saved
end

-- 缓存标记：列表行「已缓存」方框与「已下载」互斥（同时成立只显示已缓存，05 A5）。
library.view, library.group = "list", "books"
library.filter = {}
local cached_page = render({
    { source_id = "kavita", stable_id = "700", title = "漫画一", downloaded = true, cache_mark = true },
}, 1)
local cached_texts = Kit.texts(cached_page)
Assert.contains(cached_texts, "已缓存")
for _idx, s in ipairs(cached_texts) do
    Assert.is_true(s ~= "已下载", "缓存优先：同一行不再写已下载")
end
-- 没有缓存的已下载书维持原方框。
local dl_page = render({ { source_id = "moon", stable_id = "m1", title = "书一", downloaded = true } }, 1)
Assert.contains(Kit.texts(dl_page), "已下载")
for _idx, s in ipairs(Kit.texts(dl_page)) do
    Assert.is_true(s ~= "已缓存", "没缓存不写已缓存")
end

-- 网格：缓存标记走封面左下角同一槽位；Kobo 风格收进封面下状态行（05 A5）。
library.view = "grid"
render({ { source_id = "kavita", stable_id = "700", title = "漫画一", cache_mark = true } }, 1)
Assert.is_true(grid_opts.cached, "网格格子带缓存标记")
Assert.is_nil(grid_opts.status_icon)
display.library_style = "kobo"
render({ { source_id = "kavita", stable_id = "700", title = "漫画一", cache_mark = true } }, 1)
Assert.is_false(grid_opts.cached, "Kobo 不在封面上叠图标")
Assert.eq(grid_opts.status_icon, "cached", "Kobo 状态行槽位画缓存图标")
display.library_style = "kindle"

-- 离线书架：断网且源声明 shelf_cache 才收窄可见集，并换离线空态（05 A4/A6）。
library.view, library.group, library.filter = "grid", "books", {}
library.page = 1
network.connected, shelf_cache = false, false
requested = nil
library:fetch()
Assert.is_nil(requested.offline_only, "源没声明 shelf_cache：一行不改")
shelf_cache = true
requested = nil
library:fetch()
Assert.is_true(requested.offline_only, "断网 + 声明 shelf_cache：只列能离线读的")
Assert.is_true(library.offline)
local offline_page = library:buildPage(ctx)
local offline_texts = Kit.texts(offline_page)
Assert.contains(offline_texts, "离线：Kavita 里还没有可离线阅读的书")
Assert.contains(offline_texts, "联网后可在漫画详情里下载卷")
for _idx, b in ipairs(Kit.buttons(offline_page)) do
    Assert.is_true(b.icon ~= "download", "空态不放下载按钮")
end
-- 回连：标志清掉，空态回到普通文案。
network.connected = true
requested = nil
library:fetch()
Assert.is_nil(requested.offline_only)
Assert.is_false(library.offline)
Assert.contains(Kit.texts(render({}, 0)), "没有书籍")
