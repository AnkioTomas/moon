--[[--
desktop.pages.home.registry：第三方扩展（书源与非书源）声明的首页组件追加在内置组件之后；
id 按插件划命名空间，简写表自动补前缀；不合规、重名的拒绝；组件出错被 pcall 隔离；
保存布局时保留暂时缺席的第三方组件记录。

@module tests.desktop.home.registry_spec
--]]

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")

local BUILTIN = {
    "clock", "weather", "clock_weather", "weather_forecast", "stats", "tiles", "heatmap", "hitokoto", "excerpt",
    "history", "news",
    "recent_hero", "recent_list", "recent_cards", "random", "shelf",
}
for _idx, id in ipairs(BUILTIN) do
    package.preload["desktop.pages.home." .. id] = function() return { id = id, label = id } end
end

local home = {}
package.loaded["utils.settings"] = {
    get = function() return home end,
    save = function(_owner, values) if values then home = values end end,
}
package.loaded["desktop.pages.home.placements"] = nil

local Base = require("desktop.pages.home.base")
local deck = setmetatable({ id = "ext.kavita.on_deck", label = "On Deck", icon = "x" }, Base)
deck.__index = deck
function deck:createWidget() return { kind = "deck" } end
local boom = setmetatable({ id = "ext.kavita.boom", label = "Boom" }, Base)
boom.__index = boom
function boom:createWidget() error("render boom") end
function boom:heightRange() error("height boom") end
function boom:onActivate() error("activate boom") end

local built, settings_opened
local hello = {
    id = "hello", title = "Hello", height = 40,
    build = function(ctx, w, h) built = { ctx, w, h } return { kind = "hello" } end,
    settings = function(desktop, id) settings_opened = { desktop, id } end,
}
local extensions = {
    { id = "ext.kavita", source = true, home_widgets = {
        deck, { id = "clock", createWidget = function() end }, deck, boom,
        { id = "ext.other.x", build = function() end },
    } },
    { id = "ext.greeting", source = false, home_widgets = { hello, { id = "nobuild" }, 42 } },
}
local listed = 0
package.loaded["source.registry"] = {
    extensions = function() listed = listed + 1 return extensions end,
}
package.loaded["desktop.pages.home.registry"] = nil
local Registry = require("desktop.pages.home.registry")
Assert.eq(listed, 0, "加载模块时不碰源注册表：KOReader 加载插件期间第三方扩展还扫不全")

local components = Registry.list()
Assert.len(components, #BUILTIN + 3)
Assert.eq(components[#BUILTIN].id, "shelf", "内置在前")
Assert.eq(Registry.list(), components, "只收集一次")
Assert.eq(listed, 1)
Assert.eq(Registry.find("clock").label, "clock", "不能顶掉内置组件")
Assert.is_nil(Registry.find("ext.other.x"), "id 必须是本插件命名空间")
Assert.is_nil(Registry.find("ext.greeting.nobuild"), "简写表必须有 build")

-- 完整组件类：包了一层，行为照旧
local Deck = Registry.find("ext.kavita.on_deck")
Assert.eq(components[#BUILTIN + 1], Deck)
Assert.eq(Deck.label, "On Deck")
Assert.eq(Deck:new{}:createWidget().kind, "deck")

-- 出错的组件：渲染画空白占位，高度兜底，生命周期不向上抛
local Boom = Registry.find("ext.kavita.boom")
local b = Boom:new{}
b.ctx, b.opts = {}, { width = 10, height = 20 }
local placeholder = b:createWidget()
Assert.eq(type(placeholder), "table")
Assert.eq(b:heightRange({}, {}).height, 1)
b:activate()
Assert.is_true(b.active)

-- 简写表（非书源扩展）：补前缀、title 作组件名、build 拿到 ctx 与宽高、settings 成为设置按钮
local Hello = Registry.find("ext.greeting.hello")
Assert.eq(components[#BUILTIN + 3], Hello)
Assert.eq(Hello.label, "Hello")
local h = Hello:new{}
local ctx = { desktop = {} }
h:build(ctx, { width = 100, height = 50 })
Assert.eq(built[1], ctx)
Assert.eq(built[2], 100)
Assert.eq(built[3], 50)
Assert.eq(h:heightRange(ctx, { height = 300 }).height, 40)
local desktop = {}
---@cast desktop BookDesktop
h:showSettings(desktop)
Assert.eq(settings_opened[1], desktop)
Assert.eq(settings_opened[2], "ext.greeting.hello")
hello.build = function() error("hello boom") end
Assert.eq(type(h:createWidget()), "table", "build 抛错不崩首页")

-- 布局：缺席插件的组件不渲染，但保存时原位保留；已注册组件被删就真删
home.home_widgets = {
    { id = "clock", page = 1, order = 1, height = "default" },
    { id = "ext.gone.w", page = 2, order = 1, height = 80 },
    { id = "ext.greeting.hello", page = 1, order = 2, height = "default" },
}
local ids = Registry.enabledLayout()
Assert.eq(table.concat(ids, ","), "clock,ext.greeting.hello")
Registry.saveWidgets({ { id = "clock", page = 1, order = 1, height = "default" } })
local saved = {}
for _idx, item in ipairs(home.home_widgets) do saved[#saved + 1] = item.id end
Assert.eq(table.concat(saved, ","), "clock,ext.gone.w")
Assert.eq(home.home_widgets[2].height, 80)

for _idx, name in ipairs({ "source.registry", "utils.settings", "desktop.pages.home.registry", "desktop.pages.home.placements" }) do
    package.loaded[name] = nil
end
for _idx, id in ipairs(BUILTIN) do
    package.preload["desktop.pages.home." .. id] = nil
    package.loaded["desktop.pages.home." .. id] = nil
end
