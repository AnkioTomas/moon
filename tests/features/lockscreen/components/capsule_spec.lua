--[[--
features.lockscreen.components.capsule：背景是当前书封面时不再放同一张缩略图，卡片半透明。

@module tests.features.lockscreen.components.capsule_spec
--]]

local Assert = require("support.assert")

local conf = {}
local stacked
package.preload["utils.settings"] = function()
    return { get = function() return conf end }
end
package.preload["features.lockscreen.components.cards"] = function()
    return { stack = function(_rect, opts) stacked = opts; return {} end }
end
package.preload["features.lockscreen.components.current"] = function()
    return { cache_key = function() return "k" end }
end

package.loaded["features.lockscreen.components.capsule"] = nil
local Capsule = require("features.lockscreen.components.capsule")
local rect = { x = 0, y = 0, w = 600, h = 800 }

conf.lock_screen_background = "bing"
Capsule.blocks(rect)
Assert.is_true(stacked.thumb)
Assert.is_nil(stacked.lighten)

conf.lock_screen_background = "cover"
Capsule.blocks(rect)
Assert.is_false(stacked.thumb)
Assert.eq(stacked.lighten, 0.75)
