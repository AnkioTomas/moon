--[[-- xray 快捷动作：按 book_xray_enabled 决定可用性。 --]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(value) return value end end

-- 必须打桩：available 读的是真实配置文件，否则开发者在模拟器里关掉 X-Ray 就会让本用例变红。
local settings = {}
package.preload["utils.settings"] = function()
    return { get = function() return settings end }
end

package.loaded["ui.panel.actions.reader.xray"] = nil
local Xray = require("ui.panel.actions.reader.xray")

-- 老配置缺该键：视为开启
settings.book_xray_enabled = nil
Assert.is_true(Xray.available())

settings.book_xray_enabled = true
Assert.is_true(Xray.available())

-- 唯一会返回 false 的分支
settings.book_xray_enabled = false
Assert.is_false(Xray.available())
