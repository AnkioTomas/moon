--[[--
当前阅读大卡片：按槽高算封面宽，点按开书；书架签名变化才重建；空书架给图书馆入口。
@module tests.desktop.pages.home.recent_hero_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")
local Widget = require("ui/widget/widget")

local hero_opts, hero_builds = nil, 0
package.preload["ui.widgets.bookhero"] = function()
    return {
        widget = function(_, _, _, opts)
            hero_builds, hero_opts = hero_builds + 1, opts
            return Widget:new{ dimen = { w = opts.width, h = 150 } }, 150
        end,
    }
end
local shelf_recent, shelf_err = { stable_id = "book" }, nil
package.preload["book.catalog"] = function()
    return { recentShelf = function() return shelf_recent, {}, shelf_err end }
end

local Hero = require("desktop.pages.home.recent_hero")
local range = Hero:heightRange()
Assert.eq(range.height, 148)
Assert.is_nil(range.fill)

local opened
package.loaded["book.open"] = { book = function(_, book) opened = book end }
local ctx = { plugin = {}, source = { id = "local" }, desktop = {} }
local hero = Hero:new()
local slot = hero:build(ctx, { width = 600, height = 160 })
Assert.eq(slot:getSize().h, 160)
Assert.is_nil(slot[1][2], "hero 的高度返回值不能进控件树")
Assert.eq(hero_opts.cover_width, 98)
hero_opts.on_tap()
Assert.eq(opened, shelf_recent)
hero:build(ctx, { width = 600, height = 300 })
Assert.eq(hero_opts.cover_width, 192)

hero:activate()
local builds = hero_builds
shelf_recent = { stable_id = "book" }
hero:onEvent("shelf_changed")
Assert.eq(hero_builds, builds, "显示数据未变不重建")
shelf_recent = { stable_id = "book", percent = 42 }
hero:onEvent("shelf_changed")
Assert.eq(hero_builds, builds + 1, "进度变化重建")
hero:destroy()

shelf_recent, shelf_err = nil, "读取失败"
local desktop = { library = { filter = {}, page = 2 } }
function desktop:switchTab(tab) self.switched = tab end
slot = Hero:new():build({ desktop = desktop }, { width = 600, height = 160 })
Assert.contains(Kit.texts(slot), "读取失败")
Kit.taps(slot)[1]:onTapThemeArea(nil, Kit.tap(1, 1))
Assert.eq(desktop.switched, "library")
