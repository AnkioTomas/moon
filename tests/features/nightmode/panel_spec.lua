--[[-- 自动亮度快捷开关：有前光才可用，激活态与切换都走 nightmode 配置。 --]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(value) return value end end

local has_frontlight = true
package.preload["device"] = function()
    return { hasFrontlight = function() return has_frontlight end }
end
local conf = { auto_light = false }
package.preload["utils.settings"] = function()
    return { get = function(name) assert(name == "features.nightmode"); return conf end }
end
local set_to
package.preload["features.nightmode"] = function()
    return { setLight = function(on) set_to = on end }
end

local actions = require("features.nightmode.panel").actions()
Assert.len(actions, 1)
local autolight = actions[1]
Assert.eq(autolight.id, "autolight")
Assert.eq(autolight.scope, "desktop")
Assert.is_true(autolight.keep_open)

Assert.is_true(autolight.available())
has_frontlight = false
Assert.is_false(autolight.available())

Assert.is_false(autolight.active())
autolight.run({})
Assert.is_true(set_to, "关着时点一下打开")
conf.auto_light = true
Assert.is_true(autolight.active())
autolight.run({})
Assert.is_false(set_to)
