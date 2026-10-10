--[[--
首页组件基类：槽固定尺寸、refresh 只刷画过的矩形、暂停下发 HomePause、书架签名变了才重建。
@module tests.desktop.pages.home.base_spec
--]]
local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")

local shelf = { { stable_id = "a" } }
package.preload["book.catalog"] = function()
    return { recentShelf = function() return shelf, nil, nil end }
end

local Base = require("desktop.pages.home.base")
local Widget = require("ui/widget/widget")

local built, freed = 0, 0
local Comp = setmetatable({ id = "probe" }, Base)
Comp.__index = Comp
function Comp:createWidget()
    built = built + 1
    local w = Widget:new{ dimen = { w = 10, h = 10 }, n = built }
    w.free = function() freed = freed + 1 end
    return w
end

local desktop = { library = {} }
function desktop:switchTab(tab) self.switched = tab end
function desktop.library:reset() self.was_reset = true end
local ctx = { desktop = desktop, source = { id = "s" } }

do -- build 新建固定尺寸槽；未绘制 / 不活跃时 refresh 只换内容不刷屏
    local comp = Comp:new()
    Assert.is_false(comp.active)
    local slot = comp:build(ctx, { width = 120, height = 40 })
    Assert.eq(slot:getSize().w, 120)
    Assert.eq(slot:getSize().h, 40)
    Assert.eq(slot[1].n, 1)
    comp:refresh()
    Assert.eq(slot[1].n, 2)
    Assert.eq(freed, 1, "旧内容被释放")
    Assert.len(Kit.dirty, 0, "不活跃不刷屏")
    comp:activate()
    comp:refresh()
    Assert.len(Kit.dirty, 0, "没绘制过就没有矩形可刷")
    slot:paintTo(Kit.canvas(), 7, 9)
    comp:refresh()
    Assert.len(Kit.dirty, 1)
    Assert.eq(Kit.dirty[1].widget, desktop)
    Assert.eq(Kit.dirty[1].region.x, 7)
    Assert.eq(Kit.dirty[1].region.y, 9)
    Assert.eq(Kit.dirty[1].region.h, 40)
    comp:destroy()
    Assert.is_nil(comp.slot)
    comp:refresh()
end

do -- deactivate 向槽内下发 HomePause（封面取消在飞下载）
    local comp = Comp:new()
    comp:build(ctx, { width = 10, height = 10 })
    local paused = 0
    comp.slot[1].onHomePause = function() paused = paused + 1 end
    comp:activate()
    comp:deactivate()
    comp:deactivate()
    Assert.eq(paused, 1, "只在翻转时下发")
    comp:destroy()
end

do -- resume / pause 幂等，只在翻转时回调
    local comp = Comp:new()
    local log = {}
    function comp:onActivate() log[#log + 1] = "r" end
    function comp:onDeactivate() log[#log + 1] = "p" end
    function comp:onDestroy() log[#log + 1] = "d" end
    comp:build(ctx, { width = 10, height = 10 })
    comp:activate()
    comp:activate()
    comp:deactivate()
    comp:deactivate()
    comp:activate()
    comp:destroy()
    Assert.eq(table.concat(log), "rprpd")
end

do -- shelf_changed：签名变了才重建，没登记 / 不活跃忽略
    local comp = Comp:new()
    comp:build(ctx, { width = 10, height = 10 })
    comp.shelf_key = Base.shelfKey(shelf, nil, nil)
    comp:activate()
    local before = built
    comp:onEvent("shelf_changed")
    Assert.eq(built, before, "同内容新表不重建")
    shelf = { { stable_id = "b" } }
    comp:onEvent("home_refresh")
    Assert.eq(built, before, "其它事件基类不处理")
    comp:onEvent("shelf_changed")
    Assert.eq(built, before + 1)
    comp:deactivate()
    shelf = { { stable_id = "c" } }
    comp:onEvent("shelf_changed")
    Assert.eq(built, before + 1)
    Assert.eq(Base.shelfKey({ a = 1, b = { 2 } }), Base.shelfKey({ b = { 2 }, a = 1 }))
    comp:destroy()
end

do -- 空书架入口：点按清掉图书馆筛选 / 分页并切页签
    local prompt = Base.libraryPrompt(ctx, 200, 60)
    Assert.contains(Kit.texts(prompt), "去图书馆挑一本 ›")
    prompt:paintTo(Kit.canvas(), 0, 0)
    Kit.taps(prompt)[1]:onTapThemeArea(nil, { pos = { x = 5, y = 5 } })
    Assert.eq(desktop.switched, "library")
    Assert.is_true(desktop.library.was_reset)
    Assert.contains(Kit.texts(Base.libraryPrompt({}, 200, 60, "读取失败")), "读取失败")
end
