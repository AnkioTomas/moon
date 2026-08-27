--[[-- xray 快捷动作：设置页应显示为可配置。 --]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(value) return value end end

local Xray = require("ui.panel.actions.reader.xray")

Assert.is_true(Xray.available(nil))
Assert.is_true(Xray.available({ ui = nil }))
Assert.is_true(Xray.available({ ui = {} }))
