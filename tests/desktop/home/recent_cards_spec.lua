--[[--
最近阅读封面堆叠：最多九本、底边对齐、不出框；箭头 / 滑动循环切焦点只重建自己；
空书架给图书馆入口；暂停下发 HomePause。
@module tests.desktop.pages.home.recent_cards_spec
--]]
local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")
local Widget = require("ui/widget/widget")

local covers = {}
package.preload["ui.widgets.book"] = function()
    return {
        cover = function(_, _, book, cw, ch, opts)
            local w = Widget:new{ dimen = { w = cw, h = ch }, book = book, shadow = opts.shadow }
            function w:onHomePause() self.paused = true end
            covers[#covers + 1] = w
            return w
        end,
        author = function(book) return book.authors or "" end,
        pct = function(book) return book.percent or 0 end,
        title = function(book) return book.title end,
    }
end
local recent, reading = nil, {}
package.preload["book.catalog"] = function()
    return { recentShelf = function() return recent, reading, nil end }
end
local opened
package.preload["desktop.open"] = function() return { book = function(_, book) opened = book end } end

local Cards = require("desktop.pages.home.recent_cards")
Assert.eq(Cards:heightRange().height, 220)

local ctx = { desktop = {}, plugin = {}, source = { id = "local" } }
recent = { title = "心挣", authors = "初禾", percent = 25 }

do -- 单本：一张正面封面，无箭头
    local cards = Cards:new()
    local slot = cards:build(ctx, { width = 600, height = 220 })
    Assert.eq(slot:getSize().h, 220)
    Assert.len(covers, 1)
    Assert.is_true(covers[1].shadow)
    local texts = Kit.texts(slot)
    Assert.contains(texts, "心挣")
    Assert.contains(texts, "作者：初禾")
    Assert.contains(texts, "已读 25%")
    Assert.len(Kit.taps(slot), 2, "说明区 + 封面")
    cards:destroy()
end

do -- 九本：底边对齐、不出框；侧封面在两边
    for i = 1, 10 do reading[i] = { title = "b" .. i } end
    covers = {}
    local cards = Cards:new()
    local slot = cards:build(ctx, { width = 600, height = 220 })
    Assert.len(covers, 9, "最多九本")
    Assert.len(Kit.taps(slot), 12, "说明区 + 九封面 + 两箭头")
    local stack = slot[1][1][1][1][1]
    Assert.len(stack, 11)
    local bottom
    for i = 1, 9 do
        local cell = stack[i]
        local size = cell:getSize()
        local edge = cell.overlap_offset[2] + size.h
        bottom = bottom or edge
        Assert.eq(edge, bottom, "所有封面共用底边")
        Assert.is_true(cell.overlap_offset[1] >= 0)
        Assert.is_true(cell.overlap_offset[1] + size.w <= stack.dimen.w)
    end
    Assert.is_true(stack[1][1].side < 0)
    Assert.is_true(stack[2][1].side > 0)
    Assert.eq(stack[9][1].book, recent, "中间封面最后画")

    cards:activate()
    slot:paintTo(Kit.canvas(), 0, 50)
    Kit.taps(stack[11])[1]:onTapThemeArea(nil, Kit.tap(1, 1))
    Assert.eq(cards.focus, 2)
    Assert.len(Kit.dirty, 1, "只刷自己的矩形")
    Assert.eq(Kit.dirty[1].region.y, 50)
    local host = slot[1][1]
    host:onSwipeCards({ direction = "east" })
    Assert.eq(cards.focus, 1)
    host:onSwipeCards({ direction = "east" })
    Assert.eq(cards.focus, 9, "左翻循环到最后一本")
    stack = slot[1][1][1][1][1]
    Kit.taps(stack[9])[1]:onTapThemeArea(nil, Kit.tap(1, 1))
    Assert.eq(opened.title, "b8", "点中间封面开当前焦点")

    cards:deactivate()
    Assert.is_true(covers[#covers].paused, "暂停下发 HomePause")
    cards:destroy()
end

do -- 空书架：图书馆入口
    recent = nil
    local desktop = { library = { reset = function() end } }
    function desktop:switchTab(tab) self.switched = tab end
    local slot = Cards:new():build({ desktop = desktop }, { width = 600, height = 220 })
    Assert.eq(Kit.texts(slot)[1], "去图书馆挑一本 ›")
    Kit.taps(slot)[1]:onTapThemeArea(nil, Kit.tap(1, 1))
    Assert.eq(desktop.switched, "library")
end
