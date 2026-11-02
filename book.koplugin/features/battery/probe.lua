--[[--
读 Linux 电源节点，算出电池健康度。

健康度 = 现在充满 / 设计容量，两边都先换成毫安时再除。
内核约定是微伏、微安、微安时，bd71827 遵守。Kindle 的 max77696 / max77796 不遵守：
电压写成毫伏，电流写成毫安，charge_now 和 charge_full 写成毫安时，
只有 charge_full_design 仍是微安时。直接拿原始值相除，Oasis 上就是 0.1%。

单节锂电的电压要么 ~4e6 微伏，要么 ~4000 毫伏，中间没有合法值，用它判断这组节点的单位。
没有电压时，充满和设计容量都 ≥10 万才当成微安时。没有设计容量的机型算不了，
调用方应把 `report` 交给用户转给开发者，禁止把缺失补成 0。

温度是内核的 0.1°C。
`fs` 可注入：`read(path)` 返回内容或 nil，`list(path)` 返回子项名。

@module koplugin.book.features.battery.probe
--]]

local Probe = {}

local ROOT = "/sys/class/power_supply"
local MODEL = "/proc/device-tree/model"
local CLIP = 240
-- 0.1 V 的微伏数。毫伏读数是几千，到不了这里。
local MICRO_VOLT = 100000
-- 10 A。这些设备的毫安读数到不了；醒着时的微安读数过得去。
local MICRO_AMP = 10000
-- 100 mAh。设计容量写成微安时都在这之上，写成毫安时都在这之下。
local MICRO_AH = 100000

---@param raw string|nil
---@return string|nil
local function clean(raw)
    if not raw then return nil end
    raw = raw:gsub("%z", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if raw == "" then return nil end
    return raw
end

---@param raw string|nil
---@return number|nil
local function num(raw)
    raw = clean(raw)
    if not raw then return nil end
    return tonumber(raw)
end

---@param raw string
---@return string
local function clip(raw)
    raw = raw:gsub("%z", ""):gsub("[\r\n]+", " "):gsub("%s+$", "")
    if #raw > CLIP then return raw:sub(1, CLIP) .. "…" end
    return raw
end

--- 电压。返回伏特，以及这组节点是否按内核的微单位来写。
---@param raw number|nil
---@return number|nil
---@return boolean
local function voltage_v(raw)
    if not raw then return nil, false end
    if math.abs(raw) >= MICRO_VOLT then return raw / 1000000, true end
    return raw / 1000, false
end

--- 电量换成毫安时。micro 为真时节点是微安时；否则小值已经是毫安时，大值仍是微安时。
---@param raw number|nil
---@param micro boolean
---@return number|nil
local function charge_mah(raw, micro)
    if not raw then return nil end
    if micro or math.abs(raw) >= MICRO_AH then return raw / 1000 end
    return raw
end

---@param raw number|nil
---@param micro boolean
---@return number|nil
local function current_ma(raw, micro)
    if not raw then return nil end
    if micro or math.abs(raw) >= MICRO_AMP then return raw / 1000 end
    return raw
end

---@param values table<string, string>
---@return table
local function reading(name, values)
    local full = num(values.charge_full)
    local design = num(values.charge_full_design)
    local now = num(values.charge_now)
    local temp = num(values.temp)
    local volts, micro = voltage_v(num(values.voltage_now))
    if not micro and full and design and math.abs(full) >= MICRO_AH and math.abs(design) >= MICRO_AH then
        micro = true
    end
    local full_mah = charge_mah(full, micro)
    local design_mah = charge_mah(design, micro)
    local health_pct = nil
    if full_mah and design_mah and design_mah > 0 then
        health_pct = full_mah / design_mah * 100
    end
    return {
        name = name,
        health_pct = health_pct,
        cycles = num(values.battery_cycle) or num(values.cycle_count),
        charge_full_mah = full_mah,
        charge_design_mah = design_mah,
        charge_now_mah = charge_mah(now, micro),
        capacity = num(values.capacity),
        status = clean(values.status),
        health = clean(values.health),
        temp_c = temp and temp / 10 or nil,
        voltage_v = volts,
        current_ma = current_ma(num(values.current_now), micro),
    }
end

---@param fs table
---@param model string|nil
---@return string
local function report(fs, model)
    local lines = {}
    if model then lines[#lines + 1] = "model=" .. model end
    local nodes = fs.list(ROOT)
    if #nodes == 0 then lines[#lines + 1] = "power_supply: none" end
    for _idx, name in ipairs(nodes) do
        local dir = ROOT .. "/" .. name
        for _j, file in ipairs(fs.list(dir)) do
            local raw = fs.read(dir .. "/" .. file)
            if raw then
                lines[#lines + 1] = dir .. "/" .. file .. "=" .. clip(raw)
            end
        end
    end
    return table.concat(lines, "\n")
end

--- 读电源节点。没有设计容量时 `supported` 为假，`reading` 仍可能有电量百分比。
---@param fs table|nil
---@return { supported: boolean, reading: table|nil, report: string } report 仅在不支持时有内容
function Probe.read(fs)
    fs = fs or require("utils.fs")
    local model = clean(fs.read(MODEL))
    local nodes = fs.list(ROOT)
    local bats = {}
    for _idx, name in ipairs(nodes) do
        local dir = ROOT .. "/" .. name
        local values = {}
        for _j, file in ipairs(fs.list(dir)) do
            local raw = fs.read(dir .. "/" .. file)
            if raw then values[file] = raw end
        end
        if clean(values.type) == "Battery" then
            bats[#bats + 1] = { name = name, values = values }
        end
    end
    table.sort(bats, function(a, b) return a.name < b.name end)
    local chosen = nil
    for _idx, bat in ipairs(bats) do
        local design = num(bat.values.charge_full_design)
        local full = num(bat.values.charge_full)
        if design and design > 0 and full then
            chosen = bat
            break
        end
    end
    if not chosen then chosen = bats[1] end
    local row = chosen and reading(chosen.name, chosen.values) or nil
    local supported = row ~= nil and row.health_pct ~= nil
    return {
        supported = supported,
        reading = row,
        -- 诊断报告要把整棵 power_supply 再读一遍，只在不支持、用户要反馈时才有用。
        report = supported and "" or report(fs, model),
    }
end

return Probe
