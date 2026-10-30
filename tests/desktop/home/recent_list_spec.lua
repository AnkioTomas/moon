--[[--
最近阅读网格：行列设置夹紧、按行列算高度、分页只重建自己、暂停下发 HomePause、设置 Sheet；
分配高度不够两行时压封面，不能往屏幕外画。
@module tests.desktop.pages.home.recent_list_spec
--]]
local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")
local Themed = require("support.theme_stubs")
Themed.install()
local Widget = require("ui/widget/widget")

Kit.sections.home = {}
local covers, opened = {}, {}
package.preload["ui.widgets.book"] = function()
    return {
        captionExtra = function(show_title, show_author)
            return (show_title ~= false and 26 or 0) + (show_author and 14 or 0)
        end,
        isRead = function(book) return tonumber(book and book.read_state) == 1 end,
    }
end
package.preload["ui.widgets.cover"] = function()
    return {
        gridCoverMaxH = function() return 200 end,
        stretchW = function(_, cw) return cw end,
        -- 图书馆开了作者也不该影响最近阅读列表，桩里故意给 true 验证解耦。
        libraryConf = function() return { kobo = false, author = true } end,
        denseCoverMetrics = function(_, _, opts)
            return 100, 100, 150, opts.min_cols, 8, 10, 150 + opts.title_extra
        end,
        opener = function(owner) return function(book) opened[#opened + 1] = { owner = owner, book = book } end end,
        build = function(_, book, slot_w, cw, ch, on_open, show_status, show_title, show_author)
            local cell = Widget:new{ dimen = { w = slot_w, h = ch + (show_title and 26 or 0) + (show_author and 14 or 0) } }
            covers[#covers + 1] = { book = book, w = cw, h = ch, cell = cell, more = show_status, author = show_author, on_open = on_open }
            function cell:onHomePause() self.paused = true end
            return cell
        end,
    }
end
local shelf, first = {}, nil
package.preload["book.catalog"] = function()
    return { recentShelf = function() return first, shelf, nil end }
end

local List = require("desktop.pages.home.recent_list")
local Text = require("ui.themes.widgets.text")
local SECTION = Text.line("caption", "0"):getSize().h + 4
local PAGER = 40

Assert.eq(List.rows(), 2)
Assert.eq(List.cols(), 4)
Assert.is_true(List.showTitle())
List.saveShowTitle(false)
Assert.is_false(List.showTitle())
List.saveShowTitle(true)
Assert.is_false(List.showAuthor(), "作者缺省关，不跟图书馆设置")
List.saveShowAuthor(true)
Assert.is_true(List.showAuthor())
List.saveShowAuthor(false)
Assert.is_false(List.showAuthor())
List.saveCols(2)
Assert.eq(List.cols(), 3)
List.saveCols(9)
Assert.eq(List.cols(), 8)
List.saveCols(4)
List.saveRows(0)
Assert.eq(List.rows(), 2, "非法行数回退两行")

-- 空书架只有一页：不留分页条高度
local range = List:heightRange({}, { width = 600 })
Assert.eq(range.height, SECTION + 176 * 2 + 10)
Assert.is_nil(range.fill)
List.saveRows(1)
Assert.eq(List:heightRange({}, { width = 600 }).height, SECTION + 176)
List.saveShowTitle(false)
Assert.eq(List:heightRange({}, { width = 600 }).height, SECTION + 150)
List.saveShowTitle(true)
List.saveShowAuthor(true)
Assert.eq(List:heightRange({}, { width = 600 }).height, SECTION + 190, "显示作者多一行高度")
List.saveShowAuthor(false)
for i = 1, 5 do shelf[i] = { title = "book" .. i } end
Assert.eq(List:heightRange({}, { width = 600 }).height, SECTION + PAGER + 176, "一行四列五本两页：留分页条")
List.saveRows(2)
local events = {}
local desktop = { plugin = {}, onEvent = function(_, e) events[#events + 1] = e end }
local ctx = { desktop = desktop, source = { id = "local" } }

do -- 一页装下：五本、不画分页条；开书状态挂在组件实例上
    local list = List:new()
    local h = List:heightRange(ctx, { width = 600 }).height
    Assert.eq(h, range.height)
    local slot = list:build(ctx, { width = 600, height = h })
    Assert.eq(slot:getSize().h, h)
    Assert.len(Kit.buttons(slot), 0, "单页没有翻页按钮")
    Assert.is_false(list.paged)
    Assert.len(covers, 5)
    Assert.eq(covers[1].w, 100)
    Assert.is_false(covers[1].author, "图书馆开作者时最近阅读仍按自己开关（缺省关）")
    Assert.is_true(covers[1].more)
    Assert.eq(Kit.texts(slot)[1], "最近阅读 · 5")
    covers[1].on_open(shelf[1])
    Assert.eq(opened[1].owner, list)
    list:activate()
    list:deactivate()
    Assert.is_true(covers[1].cell.paused, "暂停下发 HomePause 取消封面请求")
    list:destroy()
end

do -- 一行三列：两页；翻页只重建自己并局部刷新；换源回第一页
    List.saveRows(1)
    List.saveCols(3)
    covers = {}
    local list = List:new()
    local slot = list:build(ctx, { width = 600, height = 250 })
    list:activate()
    slot:paintTo(Kit.canvas(), 0, 40)
    Assert.len(covers, 3)
    Assert.matches(table.concat(Kit.texts(slot), "|"), "1 / 2")
    covers = {}
    local next_btn = Kit.buttons(slot)[2]
    next_btn.callback()
    Assert.eq(list.page, 2)
    Assert.len(covers, 2)
    Assert.len(Kit.dirty, 1)
    Assert.eq(Kit.dirty[1].region.y, 40)
    list:onEvent("source_changed")
    Assert.is_nil(list.page)
    list:destroy()
end

do -- 书架变化让分页条出现 / 消失：高度跟着变，交给首页整页重排
    List.saveRows(1)
    List.saveCols(3)
    local home_events = {}
    local list = List:new{ home = { onEvent = function(_, e) home_events[#home_events + 1] = e end } }
    list:build(ctx, { width = 600, height = 250 })
    list:activate()
    Assert.is_true(list.paged)
    list:onEvent("shelf_changed")
    Assert.len(home_events, 0, "分页条不变不重排")
    local saved = shelf
    shelf = { saved[1] }
    list:onEvent("shelf_changed")
    Assert.eq(home_events[1], "home_changed")
    shelf = saved
    list:destroy()
end

do -- 空书架：居中提示，不画网格
    local saved = shelf
    shelf = {}
    local slot = List:new():build(ctx, { width = 600, height = 250 })
    Assert.contains(Kit.texts(slot), "没有在读的书")
    Assert.contains(Kit.texts(slot), "最近阅读")
    shelf = saved
end

do -- 设置 Sheet：行数按钮行、列数 Spin、标题 / 作者开关，改完通知首页刷新
    List.saveRows(2)
    List.saveCols(4)
    List:showSettings(desktop)
    local sheet = Themed.last("sheet")
    Assert.eq(sheet.title, "最近阅读列表")
    Assert.eq(sheet.items[1].buttons[1].text, "一行")
    Assert.eq(sheet.items[1].buttons[2].text, "✓ 两行")
    Assert.eq(sheet.items[2].text, "每行 4 本")
    Assert.eq(sheet.items[3].text, "✓ 显示标题")
    Assert.eq(sheet.items[4].text, "显示作者")
    sheet.items[1].buttons[2].callback()
    Assert.len(events, 0, "选中当前值不刷新")
    sheet.items[1].buttons[1].callback()
    Assert.eq(List.rows(), 1)
    Assert.eq(events[1], "home_refresh")
    sheet.items[3].callback()
    Assert.is_false(List.showTitle())
    sheet.items[4].callback()
    Assert.is_true(List.showAuthor())
    sheet.items[2].callback()
    local spin = Themed.last("spin")
    Assert.eq(spin.title, "每行数量")
    Assert.eq(spin.fields[1].value, 4)
    Assert.eq(spin.fields[1].min, 3)
    Assert.eq(spin.fields[1].max, 8)
    spin.callback(5)
    Assert.eq(List.cols(), 5)
    Assert.len(events, 4)
    List.saveShowTitle(true)
    List.saveShowAuthor(false)
    Assert.eq(sheet.items[5].text, "显示第一本", "缺省不显示第一本")
    sheet.items[5].callback()
    Assert.is_true(List.showFirst())
    Assert.len(events, 5)
    List.saveShowFirst(false)
    Assert.eq(sheet.items[6].text, "隐藏已读完", "缺省不隐藏已读完")
    sheet.items[6].callback()
    Assert.is_true(List.hideFinished())
    Assert.len(events, 6)
    List.saveHideFinished(false)
end

do -- 第一本：缺省不进列表；打开后排最前、计入数量
    List.saveRows(2)
    List.saveCols(4)
    first = { title = "first" }
    covers = {}
    local slot = List:new():build(ctx, { width = 600, height = 500 })
    Assert.eq(covers[1].book.title, "book1")
    Assert.eq(Kit.texts(slot)[1], "最近阅读 · 5")
    List.saveShowFirst(true)
    covers = {}
    slot = List:new():build(ctx, { width = 600, height = 500 })
    Assert.eq(covers[1].book, first)
    Assert.len(covers, 6)
    Assert.eq(Kit.texts(slot)[1], "最近阅读 · 6")
    List.saveShowFirst(false)
    first = nil
end

do -- 隐藏已读完：丢掉 read_state=1 的第一本与其余在读
    List.saveRows(2)
    List.saveCols(4)
    List.saveShowFirst(true)
    first = { title = "done", read_state = 1 }
    shelf = {
        { title = "open", read_state = 0 },
        { title = "done2", read_state = 1 },
        { title = "open2", read_state = 0 },
    }
    covers = {}
    local slot = List:new():build(ctx, { width = 600, height = 500 })
    Assert.len(covers, 4, "缺省不过滤：第一本 + 其余三本")
    List.saveHideFinished(true)
    covers = {}
    slot = List:new():build(ctx, { width = 600, height = 500 })
    Assert.len(covers, 2)
    Assert.eq(covers[1].book.title, "open")
    Assert.eq(covers[2].book.title, "open2")
    Assert.eq(Kit.texts(slot)[1], "最近阅读 · 2")
    List.saveHideFinished(false)
    List.saveShowFirst(false)
    first = nil
    shelf = {}
    for i = 1, 5 do shelf[i] = { title = "book" .. i } end
end

do -- 分配高度不够两行：封面压到装得下
    List.saveRows(2)
    List.saveCols(4)
    covers = {}
    List:new():build(ctx, { width = 600, height = SECTION + 100 })
    Assert.is_true(covers[1].h <= 50 - 26)
    Assert.is_true(covers[1].w >= 1)
end
