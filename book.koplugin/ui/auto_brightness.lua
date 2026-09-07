--[[--
环境光自动亮度控制器。

只在设备同时具备前光和环境光传感器时工作。能力优先看
Device:hasLightSensor()；未声明时再探测 sysfs / LIPC。传感器不可用时不创建
定时任务，也不修改设备亮度。

@module koplugin.book.ui.auto_brightness
--]]

require("l10n").apply()

local Device = require("device")
local UIManager = require("ui/uimanager")
local Settings = require("utils.settings")

local SAMPLE_INTERVAL = 60
local REQUIRED_STABLE_SAMPLES = 2
local LIPC_ALS_PATH = "powerd:alsLux"

local DIRECT_ALS_PATHS = {
    "/sys/class/als/als0/illuminance",
    "/sys/class/als/als1/illuminance",
    "/sys/class/illuminance/illuminance0/illuminance",
    "/sys/class/iio/devices/iio:device0/in_illuminance_input",
    "/sys/class/iio/devices/iio:device1/in_illuminance_input",
    "/sys/class/iio/devices/iio:device2/in_illuminance_input",
    "/sys/class/iio/devices/iio:device3/in_illuminance_input",
    "/sys/bus/iio/devices/iio:device0/in_illuminance_input",
    "/sys/bus/iio/devices/iio:device1/in_illuminance_input",
    "/sys/bus/iio/devices/iio:device2/in_illuminance_input",
    "/sys/bus/iio/devices/iio:device3/in_illuminance_input",
}

-- lux 达到某个阈值后使用对应的 KOReader 前光档位。
local DEFAULT_CURVE = {
    { 0, 8 }, { 3, 9 }, { 10, 10 }, { 25, 11 }, { 50, 12 },
    { 100, 13 }, { 200, 14 }, { 350, 15 }, { 700, 16 },
    { 5000, 0 }, { math.huge, 0 },
}

---@class BookAutoBrightness
---@field isSupported fun(): boolean
---@field isEnabled fun(): boolean
---@field start fun(): boolean
---@field stop fun(persist: boolean|nil): void
---@field toggle fun(): boolean
---@field bootstrap fun(): void
---@field onSuspend fun(): void
---@field onResume fun(): void
---@field shutdown fun(): void
---@field onManualBrightness fun(intensity: number): void

local AutoBrightness = {
    enabled = false,
    suspended = false,
    supported = nil,
    sensor_path = nil,
    sensor_source = nil,
    lipc_handle = nil,
    owns_lipc = false,
    native_auto_before = nil,
    powerd = nil,
    original_set_intensity = nil,
    wrapped_set_intensity = nil,
    sample_task = nil,
    next_task = nil,
    schedule_serial = 0,
    candidate_level = nil,
    candidate_count = 0,
    last_level = nil,
    internal_write = false,
    bootstrapped = false,
}

---@return table
local function powerDevice()
    return Device:getPowerDevice()
end

---@return boolean
local function hasFrontlight()
    return Device.hasFrontlight and Device:hasFrontlight()
end

--- KOReader 已声明环境光传感器。Kindle 用这个标志，不靠此刻能否读到 lux。
---@return boolean
local function hasDeclaredALS()
    return Device.hasLightSensor and Device:hasLightSensor()
end

---@param path string
---@return number|nil
function AutoBrightness:readALSPath(path)
    local file = io.open(path, "r")
    if not file then return nil end
    local value = tonumber(file:read("*a"))
    file:close()
    if value and value >= 0 then return value end
    return nil
end

---@return boolean
function AutoBrightness:openLipc()
    if self.lipc_handle then return true end
    local powerd = powerDevice()
    if powerd and powerd.lipc_handle then
        self.lipc_handle = powerd.lipc_handle
        self.owns_lipc = false
        return true
    end
    local ok, lipc = pcall(require, "liblipclua")
    if not ok or not lipc then return false end
    self.lipc_handle = lipc.init("com.github.koreader.book.autobrightness")
    self.owns_lipc = self.lipc_handle ~= nil
    return self.lipc_handle ~= nil
end

---@return number|nil
function AutoBrightness:readPowerdALS()
    if not self:openLipc() then return nil end
    local ok, value = pcall(function()
        return self.lipc_handle:get_int_property("com.lab126.powerd", "alsLux")
    end)
    if not ok or type(value) ~= "number" then return nil end
    -- 属性存在即为传感器接口；未就绪时 Kindle 返回 -1，按 0 lux 处理。
    return math.max(0, value)
end

---@param name string
---@return number|nil
function AutoBrightness:getPowerdProperty(name)
    if not self:openLipc() then return nil end
    local ok, value = pcall(function()
        return self.lipc_handle:get_int_property("com.lab126.powerd", name)
    end)
    if ok and type(value) == "number" then return value end
    return nil
end

---@param name string
---@param value number
---@return boolean
function AutoBrightness:setPowerdProperty(name, value)
    if not self:openLipc() then return false end
    local ok = pcall(function()
        self.lipc_handle:set_int_property("com.lab126.powerd", name, value)
    end)
    return ok
end

---@return number|nil
function AutoBrightness:readALS()
    if self.sensor_path then
        local value
        if self.sensor_path == LIPC_ALS_PATH then
            value = self:readPowerdALS()
        else
            value = self:readALSPath(self.sensor_path)
        end
        if value ~= nil then return value end
        self.sensor_path = nil
    end

    for _, path in ipairs(DIRECT_ALS_PATHS) do
        local value = self:readALSPath(path)
        if value ~= nil then
            self.sensor_path = path
            self.sensor_source = "direct"
            return value
        end
    end

    local value = self:readPowerdALS()
    if value ~= nil then
        self.sensor_path = LIPC_ALS_PATH
        self.sensor_source = "powerd"
        return value
    end
    return nil
end

---@return boolean
function AutoBrightness:isSupported()
    if not hasFrontlight() then return false end
    if hasDeclaredALS() then return true end
    if self.supported ~= nil then return self.supported end
    self.supported = self:readALS() ~= nil
    return self.supported
end

---@param lux number
---@return number
function AutoBrightness:brightnessForLux(lux)
    local level = DEFAULT_CURVE[#DEFAULT_CURVE][2]
    for _, point in ipairs(DEFAULT_CURVE) do
        if lux < point[1] then break end
        level = point[2]
    end

    local powerd = powerDevice()
    local min_level = tonumber(powerd.fl_min) or 0
    local max_level = tonumber(powerd.fl_max) or 24
    return math.max(min_level, math.min(max_level, level))
end

---@return number|nil
function AutoBrightness:currentLevel()
    local powerd = powerDevice()
    if type(powerd.fl_intensity) == "number" and powerd.fl_intensity >= 0 then
        return math.floor(powerd.fl_intensity)
    end
    if powerd.frontlightIntensity then
        return math.floor(powerd:frontlightIntensity())
    end
    return nil
end

---@param level number
---@return boolean
function AutoBrightness:applyLevel(level)
    local powerd = powerDevice()
    self.internal_write = true
    if level <= (tonumber(powerd.fl_min) or 0) then
        powerd:turnOffFrontlight()
    else
        powerd:setIntensity(level)
    end
    self.internal_write = false
    return true
end

---@return void
function AutoBrightness:scheduleNext()
    if not self.enabled or self.suspended then return end
    if self.next_task then UIManager:unschedule(self.next_task) end
    self.schedule_serial = self.schedule_serial + 1
    local serial = self.schedule_serial
    self.next_task = function()
        if serial == self.schedule_serial then self:sample() end
    end
    UIManager:scheduleIn(SAMPLE_INTERVAL, self.next_task)
end

---@return void
function AutoBrightness:sample()
    if not self.enabled or self.suspended then return end
    local lux = self:readALS()
    if lux == nil then
        -- 设备声明有传感器时，单次读失败只跳过本轮，不把能力改成“不支持”。
        if hasDeclaredALS() then
            self:scheduleNext()
            return
        end
        self.supported = false
        self:stop(false)
        return
    end

    local level = self:brightnessForLux(math.max(0, math.floor(lux)))
    local actual = self:currentLevel()
    if self.last_level == nil then
        self:applyLevel(level)
        self.last_level = level
    elseif level == self.last_level then
        self.candidate_level = nil
        self.candidate_count = 0
        if actual ~= level then self:applyLevel(level) end
    elseif self.candidate_level == level then
        self.candidate_count = self.candidate_count + 1
        if self.candidate_count >= REQUIRED_STABLE_SAMPLES then
            self:applyLevel(level)
            self.last_level = level
            self.candidate_level = nil
            self.candidate_count = 0
        end
    else
        self.candidate_level = level
        self.candidate_count = 1
    end
    self:scheduleNext()
end

---@return void
function AutoBrightness:installPowerdHook()
    local powerd = powerDevice()
    if not powerd or not powerd.setIntensity then return end
    if self.powerd == powerd and self.original_set_intensity then return end

    self.powerd = powerd
    self.original_set_intensity = powerd.setIntensity
    local controller = self
    self.wrapped_set_intensity = function(instance, intensity, ...)
        if not controller.internal_write then
            controller:onManualBrightness(intensity)
        end
        return controller.original_set_intensity(instance, intensity, ...)
    end
    powerd.setIntensity = self.wrapped_set_intensity
end

---@param intensity number
---@return void
function AutoBrightness:onManualBrightness(intensity)
    if not self.enabled or self.suspended or self.internal_write then return end
    local value = tonumber(intensity)
    local powerd = powerDevice()
    local min_level = tonumber(powerd.fl_min) or 0
    if not value or value <= min_level then return end

    -- DeviceListener、FrontLightWidget 和桌面滑杆可能报告同一个写入。
    -- PowerD 缓存未变化时不是实际调光，不应关闭自动模式。
    if type(powerd.fl_intensity) == "number" and powerd.fl_intensity >= 0
            and math.floor(powerd.fl_intensity) == math.floor(value) then
        return
    end
    self:stop(true)
end

---@param persist boolean|nil
---@return void
function AutoBrightness:stop(persist)
    if not self.enabled and not self.next_task then return end
    self.enabled = false
    self.suspended = false
    self.schedule_serial = self.schedule_serial + 1
    self.candidate_level = nil
    self.candidate_count = 0
    if self.sample_task then UIManager:unschedule(self.sample_task) end
    if self.next_task then UIManager:unschedule(self.next_task) end
    if self.native_auto_before ~= nil then
        self:setPowerdProperty("flAuto", self.native_auto_before)
        self.native_auto_before = nil
    end
    if persist ~= false then
        local settings = Settings.get("display")
        settings.auto_brightness_enabled = false
        Settings.saveSection("display", settings)
    end
end

---@return boolean
function AutoBrightness:start()
    if self.enabled then return true end
    if not self:isSupported() then return false end
    self:installPowerdHook()
    self.native_auto_before = self:getPowerdProperty("flAuto")
    if self.native_auto_before ~= nil and not self:setPowerdProperty("flAuto", 0) then
        self.native_auto_before = nil
        return false
    end
    self.enabled = true
    self.suspended = false
    self.candidate_level = nil
    self.candidate_count = 0
    self.last_level = nil
    local settings = Settings.get("display")
    settings.auto_brightness_enabled = true
    Settings.saveSection("display", settings)
    self.sample_task = self.sample_task or function() self:sample() end
    UIManager:scheduleIn(0.2, self.sample_task)
    return true
end

---@return boolean
function AutoBrightness:toggle()
    if self.enabled then
        self:stop(true)
        return false
    end
    return self:start()
end

---@return boolean
function AutoBrightness:isEnabled()
    return self.enabled == true
end

---@return void
function AutoBrightness:bootstrap()
    if self.bootstrapped then return end
    self.bootstrapped = true
    if not self:isSupported() then return end
    self:installPowerdHook()
    if Settings.get("display").auto_brightness_enabled == true then
        self:start()
    end
end

---@return void
function AutoBrightness:onSuspend()
    if not self.enabled then return end
    self.suspended = true
    self.schedule_serial = self.schedule_serial + 1
    if self.sample_task then UIManager:unschedule(self.sample_task) end
    if self.next_task then UIManager:unschedule(self.next_task) end
end

---@return void
function AutoBrightness:onResume()
    if not self.enabled then return end
    self.suspended = false
    self.candidate_level = nil
    self.candidate_count = 0
    self.sample_task = self.sample_task or function() self:sample() end
    UIManager:unschedule(self.sample_task)
    UIManager:scheduleIn(0.2, self.sample_task)
end

---@return void
function AutoBrightness:shutdown()
    self:stop(false)
    if self.powerd and self.original_set_intensity
            and self.powerd.setIntensity == self.wrapped_set_intensity then
        self.powerd.setIntensity = self.original_set_intensity
    end
    if self.owns_lipc and self.lipc_handle and self.lipc_handle.close then
        self.lipc_handle:close()
    end
    self.lipc_handle = nil
    self.owns_lipc = false
    self.powerd = nil
    self.original_set_intensity = nil
    self.wrapped_set_intensity = nil
    self.supported = nil
    self.sensor_path = nil
    self.sensor_source = nil
    self.bootstrapped = false
end

---@type BookAutoBrightness
return AutoBrightness
