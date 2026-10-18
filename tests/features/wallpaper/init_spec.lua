--[[--
wallpaper：经 desktop.backdrop / modal.backdrop 挂点接入；没开不画，hollow 摘掉纯底色层并可还原。
@module tests.features.wallpaper.init_spec
--]]
---@diagnostic disable: missing-fields

local Assert = require("support.assert")
local Stubs = require("support.stubs")

Stubs.install()
local conf = { wallpaper_source = "none", wallpaper_enabled = true, wallpaper_desktop = true, wallpaper_dialog = true }
package.loaded["utils.settings"] = {
    get = function(owner) assert(owner == "features.wallpaper"); return conf end,
    save = function() end,
}

package.loaded["device"] = { screen = { getWidth = function() return 100 end, getHeight = function() return 100 end } }
package.loaded["utils.image"] = { ok = function() return true end }
package.loaded["utils.paths"] = { screensaverDir = function() return "/nonexistent" end }

local Ext = require("utils.extension")
Ext.reset()
package.loaded["features.wallpaper"] = nil
local Wallpaper = require("features.wallpaper")

local desktop = Ext.last("desktop.backdrop")
Assert.is_true(desktop ~= nil)
Assert.is_true(Ext.last("modal.backdrop") ~= nil)

local function tree()
    return { { box_w = 1, style = { bg = 1 } }, { box_w = 1, style = { bg = 1, radius = 4 } } }
end

-- 没选图源：不铺、不摘底色
do
    local page = tree()
    desktop.content(page)
    Assert.is_true(page[1].style.bg == 1)
    Assert.eq(Wallpaper.paintWindow({}, 0, 0, 10, 10, "dialog"), false)
end

-- 选了图源：只摘「只有 bg」的层，带圆角的卡片样式保留；关掉后还原
do
    conf.wallpaper_source = "custom"
    Wallpaper.invalidate()
    local page = tree()
    Assert.is_true(Wallpaper.hollow(page, "desktop"))
    Assert.is_nil(page[1].style.bg)
    Assert.eq(page[2].style.radius, 4)
    conf.wallpaper_enabled = false
    Wallpaper.hollow(page, "desktop")
    Assert.eq(page[1].style.bg, 1)
end
