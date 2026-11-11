--[[--
首页一言设置：默认勾选全部官方类型。
@module tests.desktop.home.hitokoto_settings_spec
--]]

local Assert = require("support.assert")

local setting = require("desktop.pages.home.setting")
local types = setting.defaults.home_hitokoto_types
Assert.eq(type(types), "table")
Assert.eq(table.concat(types, ""), "abcdefghijkl")
Assert.eq(setting.defaults.home_hitokoto_ttl, 3600)

return true
