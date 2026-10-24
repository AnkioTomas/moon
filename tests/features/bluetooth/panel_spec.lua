--[[-- 蓝牙快捷开关：连上设备时按钮显示设备名。 --]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(value) return value end end
package.preload["ffi/util"] = function()
    return { template = function(value, arg) return (value:gsub("%%1", tostring(arg))) end }
end
local status
package.preload["features.bluetooth"] = function()
    return { installed = function() return true end, current = function() return status end }
end

local action = require("features.bluetooth.panel").actions()[1]
Assert.is_nil(action.label(), "还没读过状态")
status = { state = "off", connections = {} }
Assert.is_nil(action.label())
status = { state = "on", connections = {} }
Assert.is_nil(action.label(), "没连上用默认名")
status = { state = "on", connections = { { name = "翻页器" } } }
Assert.eq(action.label(), "翻页器")
status = { state = "on", connections = { { name = "A" }, { name = "B" } } }
Assert.eq(action.label(), "2 台设备")

return true
