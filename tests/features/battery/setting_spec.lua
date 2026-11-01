--[[-- 电池是「我的设备 → 本机」里的单独一页，读数不拆进行里。 --]]

local Assert = require("support.assert")

package.preload["gettext"] = function() return function(text) return text end end
package.preload["l10n"] = function() return { apply = function() end } end
package.preload["ui.themes.widgets.row"] = function()
    return { widget = function(opts) return opts end }
end
package.preload["features.battery.probe"] = function()
    return {
        read = function()
            return {
                supported = true,
                reading = {
                    health_pct = 91.2,
                    cycles = 12,
                    charge_full_mah = 1000,
                    charge_design_mah = 1100,
                    charge_now_mah = 800,
                    capacity = 73,
                    status = "Charging",
                    health = "Good",
                    temp_c = 31.5,
                    voltage_v = 3.9,
                    current_ma = 120,
                },
            }
        end,
    }
end

local Ext = require("utils.extension")
local Setting = require("features.battery.setting")
Assert.eq(#Setting.entries({}), 0)

local item = Ext.list("setting.device_section")[1]
Assert.eq(item.id, "battery")
Assert.eq(item.order, 30)
Assert.eq(item.icon, "battery_android_full")
Assert.eq(item.title, "电池")
Assert.eq(item.refresh_seconds, 15)
Assert.eq(item.status(), "91.2%")
Assert.is_nil(item.rows)

local sections = item.sections()
Assert.eq(#sections, 1)
Assert.eq(sections[1].title, "电池")
local by_title = {}
for _, build in ipairs(sections[1].rows) do
    local row = build(400)
    Assert.is_true(row.icon ~= nil and row.icon ~= "", row.title)
    by_title[row.title] = row.status
end
Assert.eq(by_title["健康度"], "91.2%")
Assert.eq(by_title["循环次数"], "12")
Assert.eq(by_title["电量"], "73%")
Assert.eq(by_title["状态"], "充电中")
Assert.eq(by_title["温度"], "31.5 °C")

return true
