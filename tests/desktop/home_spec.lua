--[[--
首页拼装器：首显按屏高分页落盘；每次 updateView 新建整页；组件 resume / pause 只看「首页前台 + 本页可见」；
翻页 / 滑动 / 编辑 / 删除 / 添加都经 desktop:updateView 重建；暂停退出编辑并保存；换源不重复重建。
@module tests.desktop.home_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")
local Themed = require("support.theme_stubs")
Themed.install()

local Widget = require("ui/widget/widget")
local Base = require("desktop.pages.home.base")

local log, heights, events = {}, {}, {}
local IDS = {
    "clock", "weather", "clock_weather", "weather_forecast", "stats", "heatmap", "hitokoto", "excerpt",
    "history", "news", "recent_hero", "recent_list", "recent_cards",
}
for _, id in ipairs(IDS) do
    package.preload["desktop.pages.home." .. id] = function()
        local M = setmetatable({ id = id, label = id }, Base)
        M.__index = M
        function M:heightRange() return { height = heights[id] or 300 } end
        function M:createWidget() return Widget:new{ dimen = { w = self.opts.width, h = self.opts.height } } end
        function M:onActivate() log[#log + 1] = id .. ".resume" end
        function M:onDeactivate() log[#log + 1] = id .. ".pause" end
        function M:onDestroy() log[#log + 1] = id .. ".destroy" end
        function M:onEvent(event) events[#events + 1] = id .. ":" .. event end
        if id == "weather" then function M:showSettings(d) self.settings_for = d end end
        return M
    end
end

Kit.sections.home = {}
local Home = require("desktop.pages.home")
local Registry = require("desktop.pages.home.registry")

local desktop = { tab = "home", closed = false, updates = 0 }
function desktop:ctx() return { desktop = self, width = 600, height = 800, source = self.source } end
function desktop:updateView()
    self.updates = self.updates + 1
    self.root = self.home:updateView()
end
local home = Home:new{ desktop = desktop }
desktop.home = home
local function drain() local out = table.concat(log, ","); log = {}; return out end
local function placements() return Registry.widgets() end

do -- 首显：默认全部组件按屏高分页并落盘；未 resume 的首页不启动组件
    Assert.is_nil(Kit.sections.home.home_widgets)
    desktop:updateView()
    local list = placements()
    Assert.len(list, #IDS)
    Assert.eq(list[1].id, "clock")
    Assert.eq(list[2].page, 1)
    Assert.eq(list[3].page, 2, "每页只塞得下两个 300 高")
    Assert.eq(home.pages, 7)
    Assert.is_true(home.visible.clock and home.visible.weather)
    Assert.is_nil(home.visible.clock_weather)
    Assert.eq(drain(), "", "首页不在前台不启动组件")
    Assert.eq(desktop.root:getSize().h, 800)

    Registry.saveWidgets({
        { id = "recent_hero", page = 1, order = 1, height = "default" },
        { id = "recent_list", page = 2, order = 1, height = "default" },
    })
    desktop:updateView()
    Assert.eq(home.pages, 2)
    Assert.is_nil(home.components.clock, "移出布局的组件退役")
    Assert.matches(drain(), "clock%.destroy")
    desktop.updates = 1
end

do -- switchTab 语义：activate(true) 只记前台，紧随其后的 updateView 启动本页组件
    home:activate(true)
    Assert.eq(desktop.updates, 1, "传 changed 不自己重建")
    desktop:updateView()
    Assert.eq(drain(), "recent_hero.resume")
    home:activate()
    Assert.eq(desktop.updates, 3, "系统唤醒不传参：重建一次")
    Assert.eq(drain(), "", "已活跃的组件不重复 resume")
end

do -- 翻页：离开的页暂停，新页恢复；越界不重建；滑动同翻页
    home:turn(1)
    Assert.eq(home.page, 2)
    Assert.eq(drain(), "recent_hero.pause,recent_list.resume")
    local before = desktop.updates
    home:turn(1)
    Assert.eq(desktop.updates, before, "越界不重建")
    home:onEvent("swipe", { direction = "east" })
    Assert.eq(home.page, 1)
    Assert.eq(drain(), "recent_list.pause,recent_hero.resume")
    local pager = Kit.buttons(desktop.root)
    pager[#pager].callback()
    Assert.eq(home.page, 2, "翻页条下一页")
    home:onEvent("swipe", { direction = "east" })
    drain()
end

do -- 事件：转给组件；home_refresh / detail_dirty 重建，换源不重建（Desktop 会 switchTab）
    local before = desktop.updates
    home:onEvent("source_changed")
    Assert.eq(desktop.updates, before)
    Assert.contains(events, "recent_hero:source_changed")
    home:onEvent("home_refresh")
    Assert.eq(desktop.updates, before + 1)
    home:onEvent("home_changed")
    Assert.eq(desktop.updates, before + 2)
    desktop.tab = "library"
    home:onEvent("home_refresh")
    Assert.eq(desktop.updates, before + 2, "不在首页前台不重建")
    desktop.tab = "home"
end

do -- 长按进编辑：翻页条中间换成「添加 / 完成」；添加塞不下落新页
    heights.recent_hero, heights.recent_list = 100, 100
    Kit.sections.home.home_widgets = {
        { id = "recent_hero", page = 1, order = 1, height = "default" },
        { id = "recent_list", page = 1, order = 2, height = "default" },
    }
    desktop:updateView()
    drain()
    Assert.is_true(home.visible.recent_list)
    local function arrows()
        local n = 0
        for _, b in ipairs(Kit.buttons(desktop.root)) do
            if b.icon == "chevron_left" or b.icon == "chevron_right" then n = n + 1 end
        end
        return n
    end
    Assert.eq(home.pages, 1)
    Assert.eq(arrows(), 0, "只有一页的非编辑态不显示翻页")
    Assert.eq(desktop.root:getSize().h, 800, "隐藏翻页条保留占位，整页高度不变")
    desktop.root:onHoldHomeEdit()
    Assert.is_true(home.editing)
    Assert.eq(arrows(), 2, "编辑态仍显示左右翻页")
    Assert.is_nil(desktop.root.onHoldHomeEdit, "编辑态不再挂长按")
    local texts = {}
    for _, b in ipairs(Kit.buttons(desktop.root)) do texts[#texts + 1] = b.text or b.icon end
    Assert.contains(texts, "添加")
    Assert.contains(texts, "完成")
    Assert.len(Kit.find(desktop.root, function(w) return w.onHomeEditShieldTap ~= nil end), 2, "每个组件盖遮罩")

    for _, b in ipairs(Kit.buttons(desktop.root)) do if b.text == "添加" then b.callback() end end
    local sheet = Themed.last("sheet")
    Assert.eq(sheet.title, "添加组件")
    Assert.len(sheet.items, #IDS - 2, "只列未摆上的组件")
    heights.news = 700
    for _, item in ipairs(sheet.items) do if item.text == "news" then item.callback() end end
    local news = placements()[3]
    Assert.eq(news.id, "news")
    Assert.eq(news.page, 2, "当前页塞不下落新页")
    Assert.eq(home.page, 2)
    Assert.not_nil(home.components.news, "新组件实例由 sync 创建")
end

do -- 编辑工具：删除 / 移动 / 高度；设置按钮只给有 showSettings 的组件
    home:turn(-1)
    local bars = Kit.find(desktop.root, function(w) return w.onHomeEditBarTap ~= nil end)
    Assert.len(bars, 2)
    Kit.buttons(bars[2])[2].callback()
    local move = Themed.last("sheet")
    Assert.eq(move.title, "移动组件")
    Assert.is_true(move.items[1].buttons[1].enabled, "第二个可上移")
    Assert.is_false(move.items[1].buttons[2].enabled, "末尾不可下移")
    move.items[1].buttons[1].callback()
    Assert.eq(Registry.widgets()[1].id, "recent_list")

    bars = Kit.find(desktop.root, function(w) return w.onHomeEditBarTap ~= nil end)
    Kit.buttons(bars[1])[3].callback()
    Themed.last("sheet").items[2].callback()
    Assert.eq(Registry.widgets()[1].height, "fill")

    drain()
    Kit.buttons(bars[2])[1].callback()
    Assert.is_nil(home.components.recent_hero, "删除后退役实例")
    Assert.matches(drain(), "recent_hero%.pause,recent_hero%.destroy", "删除走完暂停 + 销毁")
end

do -- 暂停退出编辑并保存；销毁全部组件
    Assert.is_true(home.editing)
    home:deactivate()
    Assert.is_false(home.editing)
    Assert.is_false(home.active)
    for _, child in pairs(home.components) do Assert.is_false(child.active) end
    home:destroy()
    Assert.is_nil(next(home.components))
end
