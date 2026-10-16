--[[--
随机一本：同一可见期重建不换书，骰子换一本，点卡片开书，回到可见重抽；空库给图书馆入口。
@module tests.desktop.home.random_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, inject-field

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")
local Widget = require("ui/widget/widget")

local hero_opts
package.preload["ui.widgets.bookhero"] = function()
    return {
        widget = function(_, _, _, opts)
            hero_opts = opts
            return Widget:new{ dimen = { w = opts.width, h = 150 } }, 150
        end,
    }
end
local picks, excluded = 0, nil
local next_book = { stable_id = "b1" }
local opened
package.loaded["desktop.open"] = { book = function(_, book) opened = book end }

local Random = require("desktop.pages.home.random")
Random.randomBook = function(source_id, exclude)
    Assert.eq(source_id, "local")
    picks, excluded = picks + 1, exclude
    return next_book
end
Assert.eq(Random.id, "random")
Assert.eq(Random:heightRange().height, 148)

local ctx = { plugin = {}, source = { id = "local" }, desktop = {} }
local widget = Random:new()
local slot = widget:build(ctx, { width = 600, height = 160 })
Assert.eq(picks, 1)
Assert.is_false(hero_opts.show_progress)
Assert.is_true(hero_opts.width < 600, "右侧留出骰子")
hero_opts.on_tap()
Assert.eq(opened.stable_id, "b1")

widget:build(ctx, { width = 600, height = 160 })
Assert.eq(picks, 1, "同一可见期重建不换")

local dice
for _idx, b in ipairs(Kit.buttons(slot)) do
    if b.icon == "casino" then dice = b end
end
next_book = { stable_id = "b2" }
dice.callback()
Assert.eq(picks, 2)
Assert.eq(excluded, "b1", "换一本避开当前这本")
hero_opts.on_tap()
Assert.eq(opened.stable_id, "b2")

widget:activate()
widget:deactivate()
widget:build(ctx, { width = 600, height = 160 })
Assert.eq(picks, 3, "回到可见重抽")

next_book = nil
local desktop = { library = { reset = function() end } }
function desktop:switchTab(tab) self.switched = tab end
slot = Random:new():build({ source = { id = "local" }, desktop = desktop }, { width = 600, height = 160 })
Kit.taps(slot)[1]:onTapThemeArea(nil, Kit.tap(1, 1))
Assert.eq(desktop.switched, "library")
