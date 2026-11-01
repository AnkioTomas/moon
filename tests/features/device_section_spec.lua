--[[-- 存储、运行状态、电池都是「我的设备 → 本机」里的子页，按这个顺序排。 --]]

local Assert = require("support.assert")

package.preload["gettext"] = function() return function(text) return text end end
package.preload["l10n"] = function() return { apply = function() end } end

require("features.storage.setting")
require("features.monitor.setting")
require("features.battery.setting")

local items = {}
for _, item in ipairs(require("utils.extension").list("setting.device_section")) do
    items[#items + 1] = item
end
table.sort(items, function(a, b) return (a.order or 0) < (b.order or 0) end)

Assert.eq(#items, 3)
Assert.eq(items[1].id, "storage")
Assert.eq(items[1].title, "存储空间")
Assert.eq(items[1].icon, "storage")
Assert.eq(items[2].id, "monitor")
Assert.eq(items[2].title, "运行状态")
Assert.eq(items[2].icon, "monitoring")
Assert.eq(items[2].refresh_seconds, 10)
Assert.eq(items[2].right_icon, "swap_vert")
Assert.eq(items[3].id, "battery")
Assert.eq(items[3].title, "电池")
Assert.eq(type(items[1].status), "function")
Assert.eq(type(items[2].status), "function")
Assert.eq(type(items[3].status), "function")
Assert.eq(#require("features.storage.setting").entries({}), 0)
Assert.eq(#require("features.monitor.setting").entries({}), 0)

return true
