--[[--
读 Linux 电源节点，算出电池健康度。

健康度 = charge_full / charge_full_design。这两个文件是微安时，相除与单位无关。
Kindle 的 bd71827 把它们和 battery_cycle 都交出来；没有设计容量的机型算不了，
调用方应把 `report` 交给用户转给开发者，禁止把缺失补成 0。

温度是内核的 0.1°C。电压微伏，电流微安，电量微安时。
`fs` 可注入：`read(path)` 返回内容或 nil，`list(path)` 返回子项名。

@module koplugin.book.features.battery.probe
--]]

local Probe = {}

local ROOT = "/sys/class/power_supply"
local MODEL = "/proc/device-tree/model"
local CLIP = 240

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

---@param values table<string, string>
---@return table
local function reading(name, values)
    local full = num(values.charge_full)
    local design = num(values.charge_full_design)
    local now = num(values.charge_now)
    local temp = num(values.temp)
    local voltage = num(values.voltage_now)
    local current = num(values.current_now)
    local health_pct = nil
    if full and design and design > 0 then
        health_pct = full / design * 100
    end
    return {
        name = name,
        health_pct = health_pct,
        cycles = num(values.battery_cycle) or num(values.cycle_count),
        charge_full_mah = full and full / 1000 or nil,
        charge_design_mah = design and design / 1000 or nil,
        charge_now_mah = now and now / 1000 or nil,
        capacity = num(values.capacity),
        status = clean(values.status),
        health = clean(values.health),
        temp_c = temp and temp / 10 or nil,
        voltage_v = voltage and voltage / 1000000 or nil,
        current_ma = current and current / 1000 or nil,
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
