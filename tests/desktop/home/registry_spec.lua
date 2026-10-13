--[[--
desktop.pages.home.registry：第三方源描述表的 home 组件追加在内置组件之后；
id 不是 ext. 开头、与已有组件重名的拒绝。

@module tests.desktop.home.registry_spec
--]]

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")

local BUILTIN = {
    "clock", "weather", "clock_weather", "weather_forecast", "stats", "hitokoto", "excerpt",
    "history", "news",
    "recent_hero", "recent_list", "recent_cards",
}
for _idx, id in ipairs(BUILTIN) do
    package.preload["desktop.pages.home." .. id] = function() return { id = id, label = id } end
end

local deck = { id = "ext.kavita.on_deck", label = "On Deck" }
local descriptors = {
    ["ext.kavita"] = { home = { deck, { id = "clock" }, { id = "ext.kavita.on_deck" } } },
    ["ext.bad"] = { home = { { id = "news2" }, 42 } },
}
local listed = 0
package.loaded["source.registry"] = {
    list = function()
        listed = listed + 1
        return { { id = "local" }, { id = "ext.kavita" }, { id = "ext.bad" }, { id = "ext.none" } }
    end,
    external = function(id) return descriptors[id] end,
}

local Registry = require("desktop.pages.home.registry")
Assert.eq(listed, 0, "加载模块时不碰源注册表：KOReader 加载插件期间第三方源还扫不全")
local components = Registry.list()
Assert.len(components, #BUILTIN + 1)
Assert.eq(components[#BUILTIN].id, "recent_cards", "内置在前")
Assert.eq(components[#BUILTIN + 1], deck)
Assert.eq(Registry.list(), components, "只收集一次")
Assert.eq(listed, 1)
Assert.eq(Registry.find("ext.kavita.on_deck"), deck)
Assert.eq(Registry.find("clock").label, "clock", "不能顶掉内置组件")
Assert.is_nil(Registry.find("news2"), "第三方组件 id 必须 ext. 开头")
