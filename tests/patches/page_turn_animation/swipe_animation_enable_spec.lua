--[[--
翻页动画运行时补丁：触发开关只认 Moon 自己的键，不看 KOReader 原生 `swipe_animations`。

@module tests.patches.page_turn_animation.swipe_animation_enable_spec
--]]

local Assert = require("support.assert")
local Config = require("support.config")

local store = {}
_G.G_reader_settings = {
    isTrue = function(_, key) return store[key] == true end,
}

local calls
local screen = {
    setSwipeAnimations = function(_, on) calls[#calls + 1] = { "anim", on } end,
    setSwipeDirection = function(_, forward) calls[#calls + 1] = { "dir", forward } end,
}
local Device = { screen = screen, canDoSwipeAnimation = function() return false end }
local ReaderView = {}
package.loaded["device"] = Device
package.loaded["apps/reader/modules/readerview"] = ReaderView

dofile(Config.root() .. "/book.koplugin/patches/page_turn_animation/2-swipe-animation-enable.lua")
Assert.is_true(Device.canDoSwipeAnimation())

local view = setmetatable({}, { __index = ReaderView })

calls = {}
store.swipe_animations = true
view:onPageChangeAnimation(true)
Assert.len(calls, 0, "只开原生开关不触发软件动画")

calls = {}
store.moon_page_turn_animation = true
view:onPageChangeAnimation(true)
Assert.len(calls, 2)
Assert.eq(calls[1][2], true)
Assert.eq(calls[2][2], true)

calls = {}
store.swipe_animations = nil
view.inverse_reading_order = true
view:onPageChangeAnimation(true)
Assert.eq(calls[2][2], false, "反向阅读翻转方向")

return true
