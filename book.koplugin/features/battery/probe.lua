--[[--
读 Linux 电源节点，算出电池健康度和总容量。

健康度 = 现在充满 / 设计容量，两边都先换成毫安时再除。多块电池（有设计容量的）按毫安时求和。
内核约定是微伏、微安、微安时，bd71827 遵守。Kindle 的 max77696 / max77796 不遵守：
电压写成毫伏，电流写成毫安，charge_now 和 charge_full 写成毫安时，
只有 charge_full_design 仍是微安时。单位由 `MILLI_DRIVERS` 按节点名决定，不靠数值大小猜；
新机型违反约定时往表里加一行。

max77696 所有板子的 charge_full_design 都是平台数据里的死值 790000 µAh（790 mAh），
跟电芯无关。驱动初始化时把这颗电芯的表征容量写进电量计 DESIGNCAP（寄存器 0x18），
之后学习只改 FullCAP，不改 DESIGNCAP。同一块板子能配几种电芯（icewine 就有三套），
按机型写死必然算错。1 LSB = 0.5 mAh，和内核把 charge_full 换算成毫安时用的是同一个比例
（r_sns 默认 10000 µΩ）。读不到寄存器就不要拿 790 冒充设计容量。

没有设计容量的机型算不了，调用方应把 `report` 交给用户转给开发者，禁止把缺失补成 0。

温度是内核的 0.1°C。
`fs` 可注入：`read(path)` 返回内容或 nil，`list(path)` 返回子项名。

@module koplugin.book.features.battery.probe
--]]

local Probe = {}

local ROOT = "/sys/class/power_supply"
local MODEL = "/proc/device-tree/model"
local CLIP = 240
-- 毫单位驱动（节点名前缀），见文件头。
local MILLI_DRIVERS = { "max77696", "max77796" }
-- 只读算健康度用得到的节点；整棵树只在不支持时才为诊断报告读。
local FILES = {
    "capacity", "status", "health", "temp", "voltage_now", "current_now", "charge_now",
    "charge_full", "charge_full_design", "battery_cycle", "cycle_count",
}
-- 见文件头。固件若写出真实容量则不会撞上这块死值，也就不用再读电量计。
local MAX77696_STALE_DESIGN_MAH = 790
local I2C_DEVICES = "/sys/bus/i2c/devices"
local DESIGNCAP = 0x18
local GAUGE_LSB_MAH = 0.5
local GAUGE_MAH_MIN = 100
local GAUGE_MAH_MAX = 5000
local I2C_SLAVE = 0x0703
local I2C_SLAVE_FORCE = 0x0706
local I2C_SMBUS = 0x0720
local I2C_SMBUS_READ = 1
local I2C_SMBUS_WORD_DATA = 3

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

---@param name string
---@return boolean
local function isMilli(name)
    for _idx, prefix in ipairs(MILLI_DRIVERS) do
        if name:sub(1, #prefix) == prefix then return true end
    end
    return false
end

--- 原始读数换成「基本单位 × 1000」（mV→V、µA→mA、µAh→mAh 都是除以 1000 或 1）。
---@param raw number|nil
---@param divisor number
---@return number|nil
local function scaled(raw, divisor)
    if not raw then return nil end
    return raw / divisor
end

-- 读成功才记住。设计容量出厂写入后不再变，设置行每 15 秒刷一次，不必反复占总线。
local cached_design_mah
local gauge_ffi

local function ffi_mod()
    if gauge_ffi then return gauge_ffi end
    local ffi = require("ffi")
    -- KOReader 已经声明过 open / ioctl，签名不同时 pcall 会失败，沿用已有的。
    pcall(ffi.cdef, "int open(const char *pathname, int flags);")
    pcall(ffi.cdef, "int close(int fd);")
    pcall(ffi.cdef, "int ioctl(int fd, unsigned long request, ...);")
    pcall(ffi.cdef, [[
        typedef union {
            uint8_t byte;
            uint16_t word;
            uint8_t block[34];
        } book_gauge_smbus_data;
    ]])
    pcall(ffi.cdef, [[
        typedef struct {
            uint8_t read_write;
            uint8_t command;
            uint32_t size;
            book_gauge_smbus_data *data;
        } book_gauge_smbus_ioctl;
    ]])
    gauge_ffi = ffi
    return ffi
end

--- SMBus 读一个字。Kindle 老内核的节点是 /dev/i2c/<bus>，新的是 /dev/i2c-<bus>。
---@param bus number
---@param addr number
---@param reg number
---@return number|nil
local function i2c_word(bus, addr, reg)
    local ffi = ffi_mod()
    local fd
    for _idx, path in ipairs({ "/dev/i2c/" .. bus, "/dev/i2c-" .. bus }) do
        local opened = ffi.C.open(path, 2)
        if opened >= 0 then
            fd = opened
            break
        end
    end
    if not fd then return nil end
    local addr_ptr = ffi.cast("void*", addr)
    if ffi.C.ioctl(fd, I2C_SLAVE, addr_ptr) < 0 and ffi.C.ioctl(fd, I2C_SLAVE_FORCE, addr_ptr) < 0 then
        ffi.C.close(fd)
        return nil
    end
    local word
    for _try = 1, 3 do
        local data = ffi.new("book_gauge_smbus_data")
        local args = ffi.new("book_gauge_smbus_ioctl")
        args.read_write = I2C_SMBUS_READ
        args.command = reg
        args.size = I2C_SMBUS_WORD_DATA
        args.data = data
        -- 已有的 ioctl 是变参声明，结构体要显式转成指针，否则按值传进去总线直接 EIO。
        if ffi.C.ioctl(fd, I2C_SMBUS, ffi.cast("void*", args)) == 0 then
            word = tonumber(data.word)
            break
        end
    end
    ffi.C.close(fd)
    return word
end

--- 电量计设计容量，毫安时。`fs.i2c_word(bus, addr, reg)` 可注入，测完不用碰 /dev。
---@param fs table
---@return number|nil
local function gauge_design_mah(fs)
    if not fs.i2c_word and cached_design_mah then return cached_design_mah end
    local word_of = fs.i2c_word or i2c_word
    local mah
    for _idx, entry in ipairs(fs.list(I2C_DEVICES)) do
        local bus, hex = entry:match("^(%d+)%-(%x+)$")
        if bus and clean(fs.read(I2C_DEVICES .. "/" .. entry .. "/name")) == "max77696-battery" then
            local word = word_of(tonumber(bus), tonumber(hex, 16), DESIGNCAP)
            if word and word > 0 then
                local scaled = word * GAUGE_LSB_MAH
                if scaled >= GAUGE_MAH_MIN and scaled <= GAUGE_MAH_MAX then mah = scaled end
            end
            break
        end
    end
    if mah and not fs.i2c_word then cached_design_mah = mah end
    return mah
end

---@param name string
---@param values table<string, string>
---@param fs table
---@return table
local function reading(name, values, fs)
    local milli = isMilli(name)
    local unit = milli and 1 or 1000
    local temp = num(values.temp)
    local volts = scaled(num(values.voltage_now), unit * 1000)
    local full_mah = scaled(num(values.charge_full), unit)
    local design_mah = scaled(num(values.charge_full_design), 1000)
    if name == "max77696-battery" and design_mah == MAX77696_STALE_DESIGN_MAH then
        design_mah = gauge_design_mah(fs)
    end
    return {
        name = name,
        cycles = num(values.battery_cycle) or num(values.cycle_count),
        charge_full_mah = full_mah,
        charge_design_mah = design_mah,
        charge_now_mah = scaled(num(values.charge_now), unit),
        capacity = num(values.capacity),
        status = clean(values.status),
        health = clean(values.health),
        temp_c = temp and temp / 10 or nil,
        voltage_v = volts,
        current_ma = scaled(num(values.current_now), unit),
    }
end

--- 充满不低于设计容量时电量计没学到衰减（旧机器常见，FullCAP 还会略高于设计值），
--- 算出 100% 是假的，返回 nil 让界面说「无法判断」。
---@param full number
---@param design number
---@return number|nil
local function health(full, design)
    if full >= design then return nil end
    return full / design * 100
end

--- 多块电池合成一份：容量求和，健康度 = 总充满 / 总设计；电压、温度、状态取第一块。
---@param rows table[]
---@return table
local function total(rows)
    local out = {}
    for k, v in pairs(rows[1]) do out[k] = v end
    if #rows == 1 then
        out.health_pct = health(out.charge_full_mah, out.charge_design_mah)
        return out
    end
    local full, design, now = 0, 0, 0
    local names = {}
    for _idx, row in ipairs(rows) do
        full = full + row.charge_full_mah
        design = design + row.charge_design_mah
        now = now + (row.charge_now_mah or 0)
        names[#names + 1] = row.name
        out.cycles = math.max(out.cycles or 0, row.cycles or 0)
    end
    out.name = table.concat(names, "+")
    out.charge_full_mah = full
    out.charge_design_mah = design
    out.charge_now_mah = now
    out.health_pct = health(full, design)
    if now > 0 then out.capacity = now / full * 100 end
    return out
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
--- max77696 的设计容量节点是死值时，改读电量计 DESIGNCAP。
---@param fs table|nil
---@return { supported: boolean, reading: table|nil, report: string } report 仅在不支持时有内容
function Probe.read(fs)
    fs = fs or require("utils.fs")
    local board = clean(fs.read(MODEL))
    local bats = {}
    for _idx, name in ipairs(fs.list(ROOT)) do
        local dir = ROOT .. "/" .. name
        if clean(fs.read(dir .. "/type")) == "Battery" then
            local values = {}
            for _j, file in ipairs(FILES) do
                values[file] = fs.read(dir .. "/" .. file)
            end
            bats[#bats + 1] = reading(name, values, fs)
        end
    end
    table.sort(bats, function(a, b) return a.name < b.name end)
    local usable = {}
    for _idx, row in ipairs(bats) do
        if row.charge_design_mah and row.charge_design_mah > 0 and row.charge_full_mah then
            usable[#usable + 1] = row
        end
    end
    local row = #usable > 0 and total(usable) or bats[1]
    local supported = #usable > 0
    return {
        supported = supported,
        reading = row,
        report = supported and "" or report(fs, board),
    }
end

return Probe
