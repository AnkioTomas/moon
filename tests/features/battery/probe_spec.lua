--[[--
电池节点：有设计容量才算健康度；缺失不补 0。温度按 0.1°C。
@module tests.features.battery.probe_spec
--]]

local Assert = require("support.assert")

local Probe = require("features.battery.probe")

local tree
local gauge_word

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
        i2c_word = function(_bus, _addr, _reg) return gauge_word end,
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

-- max77696 的 charge_full_design 是板级死值 790 mAh。设计容量在电量计 DESIGNCAP，0.5 mAh/LSB。
-- 0x0B00 = 1408，0x075A = 941。不读寄存器时，充满 1380 的健康度是 1380/790。
tree = {
    ["/sys/class/power_supply/max77696-battery/type"] = "Battery\n",
    ["/sys/class/power_supply/max77696-battery/capacity"] = "75\n",
    ["/sys/class/power_supply/max77696-battery/voltage_now"] = "4100\n",
    ["/sys/class/power_supply/max77696-battery/current_now"] = "-40\n",
    ["/sys/class/power_supply/max77696-battery/charge_now"] = "1050\n",
    ["/sys/class/power_supply/max77696-battery/charge_full"] = "1380\n",
    ["/sys/class/power_supply/max77696-battery/charge_full_design"] = "790000\n",
    ["/sys/bus/i2c/devices/0-0034/name"] = "max77696-battery\n",
}
gauge_word = 0x0B00
local from_gauge = Probe.read(fs())
Assert.eq(from_gauge.reading.charge_full_mah, 1380)
Assert.eq(from_gauge.reading.charge_now_mah, 1050)
Assert.eq(from_gauge.reading.charge_design_mah, 1408)
Assert.is_true(math.abs(from_gauge.reading.health_pct - (1380 / 1408 * 100)) < 1e-6)
Assert.eq(from_gauge.reading.voltage_v, 4.1)
Assert.eq(from_gauge.reading.current_ma, -40)

gauge_word = 0x075A
local bourbon = Probe.read(fs())
Assert.eq(bourbon.reading.charge_design_mah, 941)
Assert.eq(bourbon.reading.health_pct, 100, "充满高于设计容量：估算值上限为 100%")

-- 寄存器越界（当没读到）和读失败都不用 790 冒充。
gauge_word = 0xFFFF
local huge = Probe.read(fs())
Assert.is_nil(huge.reading.health_pct)
Assert.is_nil(huge.reading.charge_design_mah)
gauge_word = nil
local unread = Probe.read(fs())
Assert.is_true(not unread.supported)
Assert.is_nil(unread.reading.health_pct)
Assert.is_nil(unread.reading.charge_design_mah)
Assert.eq(unread.reading.charge_full_mah, 1380)

-- 不是这块死值就不要碰电量计，哪怕寄存器里是另一颗电芯的数。
gauge_word = 0x075A
tree["/sys/class/power_supply/max77696-battery/charge_full_design"] = "1408000\n"
local fixed = Probe.read(fs())
Assert.eq(fixed.reading.charge_design_mah, 1408)
tree["/sys/class/power_supply/max77696-battery/charge_full_design"] = "1320000\n"
local other = Probe.read(fs())
Assert.eq(other.reading.charge_design_mah, 1320)

-- 这台 Kindle Basic 的节点：DESIGNCAP 0x075A，充满已经等于设计容量。
tree = {
    ["/sys/class/power_supply/max77696-battery/type"] = "Battery\n",
    ["/sys/class/power_supply/max77696-battery/capacity"] = "89\n",
    ["/sys/class/power_supply/max77696-battery/voltage_now"] = "4059\n",
    ["/sys/class/power_supply/max77696-battery/current_now"] = "-124\n",
    ["/sys/class/power_supply/max77696-battery/charge_now"] = "860\n",
    ["/sys/class/power_supply/max77696-battery/charge_full"] = "941\n",
    ["/sys/class/power_supply/max77696-battery/charge_full_design"] = "790000\n",
    ["/sys/class/power_supply/max77696-battery/cycle_count"] = "112\n",
    ["/sys/bus/i2c/devices/0-0034/name"] = "max77696-battery\n",
}
gauge_word = 0x075A
local basic = Probe.read(fs())
Assert.eq(basic.reading.charge_full_mah, 941)
Assert.eq(basic.reading.charge_now_mah, 860)
Assert.eq(basic.reading.charge_design_mah, 941)
Assert.eq(basic.reading.cycles, 112)
Assert.eq(basic.reading.health_pct, 100, "充满等于设计容量：仍显示电量计估算值")
Assert.is_true(basic.supported)
Assert.eq(basic.reading.voltage_v, 4.059)
Assert.eq(basic.reading.current_ma, -124)

-- 用户反馈：充满与设计都是 1293 mAh，循环 483 次；有读数不能当成读不到。
tree = {
    ["/sys/class/power_supply/bd71827_bat/type"] = "Battery\n",
    ["/sys/class/power_supply/bd71827_bat/charge_full"] = "1293000\n",
    ["/sys/class/power_supply/bd71827_bat/charge_full_design"] = "1293000\n",
    ["/sys/class/power_supply/bd71827_bat/charge_now"] = "1556000\n",
    ["/sys/class/power_supply/bd71827_bat/battery_cycle"] = "483\n",
}
local equal = Probe.read(fs())
Assert.is_true(equal.supported)
Assert.eq(equal.reading.health_pct, 100)
Assert.eq(equal.reading.charge_now_mah, 1556)
Assert.eq(equal.reading.cycles, 483)

-- 多块电池：容量求和，健康度 = 总充满 / 总设计；没设计容量的不参与。
tree = {
    ["/sys/class/power_supply/bat0/type"] = "Battery\n",
    ["/sys/class/power_supply/bat0/charge_now"] = "1000000\n",
    ["/sys/class/power_supply/bat0/charge_full"] = "2000000\n",
    ["/sys/class/power_supply/bat0/charge_full_design"] = "2500000\n",
    ["/sys/class/power_supply/bat0/battery_cycle"] = "10\n",
    ["/sys/class/power_supply/bat1/type"] = "Battery\n",
    ["/sys/class/power_supply/bat1/charge_now"] = "500000\n",
    ["/sys/class/power_supply/bat1/charge_full"] = "1000000\n",
    ["/sys/class/power_supply/bat1/charge_full_design"] = "1500000\n",
    ["/sys/class/power_supply/bat1/battery_cycle"] = "30\n",
    ["/sys/class/power_supply/bat2/type"] = "Battery\n",
}
local pair = Probe.read(fs())
Assert.is_true(pair.supported)
Assert.eq(pair.reading.charge_full_mah, 3000)
Assert.eq(pair.reading.charge_design_mah, 4000)
Assert.eq(pair.reading.charge_now_mah, 1500)
Assert.eq(pair.reading.health_pct, 75)
Assert.eq(pair.reading.capacity, 50)
Assert.eq(pair.reading.cycles, 30)

tree["/sys/class/power_supply/bat0/charge_full"] = "3000000\n"
Assert.eq(Probe.read(fs()).reading.health_pct, 100, "多电池总充满等于总设计容量")
tree["/sys/class/power_supply/bat0/charge_full"] = "3500000\n"
Assert.eq(Probe.read(fs()).reading.health_pct, 100, "多电池按总容量计算后再限制上限")
