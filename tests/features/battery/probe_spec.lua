--[[--
电池节点：有设计容量才算健康度；缺失不补 0。温度按 0.1°C。
@module tests.features.battery.probe_spec
--]]

local Assert = require("support.assert")

local Probe = require("features.battery.probe")

local tree

local function fs()
    return {
        read = function(path) return tree[path] end,
        list = function(path)
            local prefix = path .. "/"
            local seen, out = {}, {}
            for p in pairs(tree) do
                if p:sub(1, #prefix) == prefix then
                    local name = p:sub(#prefix + 1):match("^([^/]+)")
                    if name and not seen[name] then
                        seen[name] = true
                        out[#out + 1] = name
                    end
                end
            end
            table.sort(out)
            return out
        end,
    }
end

tree = {
    ["/proc/device-tree/model"] = "MT8113 Bellatrix device\0",
    ["/sys/class/power_supply/bd71827_ac/type"] = "Mains\n",
    ["/sys/class/power_supply/bd71827_ac/online"] = "0\n",
    ["/sys/class/power_supply/bd71827_bat/type"] = "Battery\n",
    ["/sys/class/power_supply/bd71827_bat/capacity"] = "84\n",
    ["/sys/class/power_supply/bd71827_bat/status"] = "Discharging\n",
    ["/sys/class/power_supply/bd71827_bat/health"] = "Good\n",
    ["/sys/class/power_supply/bd71827_bat/temp"] = "283\n",
    ["/sys/class/power_supply/bd71827_bat/voltage_now"] = "4043000\n",
    ["/sys/class/power_supply/bd71827_bat/current_now"] = "-45954\n",
    ["/sys/class/power_supply/bd71827_bat/charge_now"] = "1237000\n",
    ["/sys/class/power_supply/bd71827_bat/charge_full"] = "1450000\n",
    ["/sys/class/power_supply/bd71827_bat/charge_full_design"] = "1453000\n",
    ["/sys/class/power_supply/bd71827_bat/battery_cycle"] = "5\n",
    ["/sys/class/power_supply/bd71827_bat/battery_parameters"] = string.rep("x", 300),
}

local ok = Probe.read(fs())
Assert.is_true(ok.supported)
Assert.eq(ok.reading.name, "bd71827_bat")
Assert.is_true(math.abs(ok.reading.health_pct - (1450000 / 1453000 * 100)) < 1e-6)
Assert.eq(ok.reading.cycles, 5)
Assert.eq(ok.reading.charge_full_mah, 1450)
Assert.eq(ok.reading.charge_design_mah, 1453)
Assert.eq(ok.reading.charge_now_mah, 1237)
Assert.eq(ok.reading.capacity, 84)
Assert.eq(ok.reading.temp_c, 28.3)
Assert.eq(ok.reading.voltage_v, 4.043)
Assert.is_true(math.abs(ok.reading.current_ma - (-45.954)) < 1e-6)
Assert.eq(ok.reading.status, "Discharging")
Assert.eq(ok.reading.health, "Good")
Assert.eq(ok.report, "", "支持的设备不用诊断报告，不再整棵重读 sysfs")

tree["/sys/class/power_supply/bd71827_bat/charge_full_design"] = nil
local missing = Probe.read(fs())
Assert.is_true(not missing.supported)
Assert.eq(missing.reading.capacity, 84)
Assert.is_nil(missing.reading.health_pct)
Assert.eq(missing.reading.cycles, 5)
Assert.is_true(missing.report:find("model=MT8113 Bellatrix device", 1, true) ~= nil)
Assert.is_true(missing.report:find("bd71827_ac/type=Mains", 1, true) ~= nil)
local dumped = missing.report:match("battery_parameters=([^\n]*)")
Assert.is_true(dumped:find("…", 1, true) ~= nil)
Assert.is_true(#dumped < 260)
Assert.is_true(not missing.report:find("charge_full=1450000 ", 1, true))

tree["/sys/class/power_supply/bd71827_bat/battery_cycle"] = nil
tree["/sys/class/power_supply/bd71827_bat/cycle_count"] = "12\n"
local cycles = Probe.read(fs())
Assert.eq(cycles.reading.cycles, 12)

tree = { ["/proc/device-tree/model"] = "desk\n" }
local none = Probe.read(fs())
Assert.is_true(not none.supported)
Assert.is_nil(none.reading)
Assert.eq(none.report, "model=desk\npower_supply: none")

-- 有设计容量的那块优先，不挑名字更靠前但算不了的。
tree = {
    ["/sys/class/power_supply/aaa/type"] = "Battery\n",
    ["/sys/class/power_supply/aaa/capacity"] = "10\n",
    ["/sys/class/power_supply/zzz/type"] = "Battery\n",
    ["/sys/class/power_supply/zzz/charge_full"] = "1000\n",
    ["/sys/class/power_supply/zzz/charge_full_design"] = "2000\n",
}
local picked = Probe.read(fs())
Assert.is_true(picked.supported)
Assert.eq(picked.reading.name, "zzz")
Assert.eq(picked.reading.health_pct, 50)

-- Oasis 2 的 max77796：电压毫伏、电流毫安、充满和剩余是毫安时，设计容量仍是微安时。
-- 反馈截图上的 0.004 V、1 mAh、0.1% 就是这组数再按微单位除一次。
tree = {
    ["/sys/class/power_supply/max77796-battery/type"] = "Battery\n",
    ["/sys/class/power_supply/max77796-battery/capacity"] = "77\n",
    ["/sys/class/power_supply/max77796-battery/status"] = "Discharging\n",
    ["/sys/class/power_supply/max77796-battery/health"] = "Good\n",
    ["/sys/class/power_supply/max77796-battery/temp"] = "236\n",
    ["/sys/class/power_supply/max77796-battery/voltage_now"] = "4000\n",
    ["/sys/class/power_supply/max77796-battery/current_now"] = "-86\n",
    ["/sys/class/power_supply/max77796-battery/charge_now"] = "779\n",
    ["/sys/class/power_supply/max77796-battery/charge_full"] = "1000\n",
    ["/sys/class/power_supply/max77796-battery/charge_full_design"] = "1012000\n",
    ["/sys/class/power_supply/max77796-battery/cycle_count"] = "2\n",
}
local oasis = Probe.read(fs())
Assert.is_true(oasis.supported)
Assert.eq(oasis.reading.name, "max77796-battery")
Assert.is_true(math.abs(oasis.reading.health_pct - (1000 / 1012 * 100)) < 1e-6)
Assert.eq(oasis.reading.cycles, 2)
Assert.eq(oasis.reading.charge_full_mah, 1000)
Assert.eq(oasis.reading.charge_design_mah, 1012)
Assert.eq(oasis.reading.charge_now_mah, 779)
Assert.eq(oasis.reading.capacity, 77)
Assert.eq(oasis.reading.temp_c, 23.6)
Assert.eq(oasis.reading.voltage_v, 4)
Assert.eq(oasis.reading.current_ma, -86)
Assert.eq(oasis.reading.status, "Discharging")
Assert.eq(oasis.reading.health, "Good")

-- 遵守约定的节点，剩余很低、电流很小，仍按微单位换算。
tree = {
    ["/sys/class/power_supply/bd71827_bat/type"] = "Battery\n",
    ["/sys/class/power_supply/bd71827_bat/voltage_now"] = "3600000\n",
    ["/sys/class/power_supply/bd71827_bat/current_now"] = "-3000\n",
    ["/sys/class/power_supply/bd71827_bat/charge_now"] = "5000\n",
    ["/sys/class/power_supply/bd71827_bat/charge_full"] = "1450000\n",
    ["/sys/class/power_supply/bd71827_bat/charge_full_design"] = "1453000\n",
}
local low = Probe.read(fs())
Assert.eq(low.reading.charge_now_mah, 5)
Assert.eq(low.reading.charge_full_mah, 1450)
Assert.eq(low.reading.current_ma, -3)
Assert.eq(low.reading.voltage_v, 3.6)

-- 没有电压，但充满和设计容量都是微安时：剩余的小值也要跟着除。
tree = {
    ["/sys/class/power_supply/bat/type"] = "Battery\n",
    ["/sys/class/power_supply/bat/current_now"] = "-45954\n",
    ["/sys/class/power_supply/bat/charge_now"] = "5000\n",
    ["/sys/class/power_supply/bat/charge_full"] = "1450000\n",
    ["/sys/class/power_supply/bat/charge_full_design"] = "1453000\n",
}
local novolt = Probe.read(fs())
Assert.eq(novolt.reading.charge_now_mah, 5)
Assert.eq(novolt.reading.charge_full_mah, 1450)
Assert.eq(novolt.reading.charge_design_mah, 1453)
Assert.is_true(math.abs(novolt.reading.current_ma - (-45.954)) < 1e-6)

-- Paperwhite 3 / Voyage：max77696 的 charge_full_design 是板级死值 790000 µAh。
-- 电量计 DESIGNCAP 0x0B00 = 1408 mAh。不换的话健康度 = 现在充满 / 790。
tree = {
    ["/sys/class/power_supply/max77696-battery/type"] = "Battery\n",
    ["/sys/class/power_supply/max77696-battery/capacity"] = "75\n",
    ["/sys/class/power_supply/max77696-battery/voltage_now"] = "4100\n",
    ["/sys/class/power_supply/max77696-battery/current_now"] = "-40\n",
    ["/sys/class/power_supply/max77696-battery/charge_now"] = "1050\n",
    ["/sys/class/power_supply/max77696-battery/charge_full"] = "1380\n",
    ["/sys/class/power_supply/max77696-battery/charge_full_design"] = "790000\n",
}
local pw3 = Probe.read(fs(), "KindlePaperWhite3")
Assert.eq(pw3.reading.charge_full_mah, 1380)
Assert.eq(pw3.reading.charge_now_mah, 1050)
Assert.eq(pw3.reading.charge_design_mah, 1408)
Assert.is_true(math.abs(pw3.reading.health_pct - (1380 / 1408 * 100)) < 1e-6)
Assert.eq(pw3.reading.voltage_v, 4.1)
Assert.eq(pw3.reading.current_ma, -40)

local voyage = Probe.read(fs(), "KindleVoyage")
Assert.eq(voyage.reading.charge_design_mah, 1408)

-- 不知道机型就保持节点原值，不拿 1408 去套别的 max77696。
local unknown = Probe.read(fs())
Assert.eq(unknown.reading.charge_design_mah, 790)
Assert.is_true(math.abs(unknown.reading.health_pct - (1380 / 790 * 100)) < 1e-6)

-- 死值写成毫安时而不是微安时，同样换掉。
tree["/sys/class/power_supply/max77696-battery/charge_full_design"] = "790\n"
local milli = Probe.read(fs(), "KindlePaperWhite3")
Assert.eq(milli.reading.charge_design_mah, 1408)

-- 不是这块板级死值就不要改，哪怕机型对得上。
tree["/sys/class/power_supply/max77696-battery/charge_full_design"] = "1408000\n"
local fixed = Probe.read(fs(), "KindlePaperWhite3")
Assert.eq(fixed.reading.charge_design_mah, 1408)
tree["/sys/class/power_supply/max77696-battery/charge_full_design"] = "1320000\n"
local other = Probe.read(fs(), "KindlePaperWhite3")
Assert.eq(other.reading.charge_design_mah, 1320)
