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
