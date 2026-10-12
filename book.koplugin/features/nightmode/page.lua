--[[--
自动夜间 / 自动亮度的设置行（追加在桌面「界面显示」页，入口见 setting.lua）。

@module koplugin.book.features.nightmode.page
--]]

local Device = require("device")
local List = require("ui.themes.widgets.list")
local Spin = require("ui.themes.widgets.spin")
local Toast = require("ui.themes.widgets.toast")
local Row = require("ui.themes.widgets.row")
local MoonSettings = require("utils.settings")
local NightMode = require("features.nightmode")
local _ = require("gettext")
local T = require("ffi/util").template

local Page = {}

---@param minute number
---@return string
local function clock(minute)
    return string.format("%02d:%02d", math.floor(minute / 60), minute % 60)
end

--- 应用模式并报今天的开关时间；KOReader 自带的自动夜间模式也开着时提醒，两者会互相覆盖。
---@param desktop table
---@param mode "off"|"schedule"|"sun"
---@param head string|nil 首行提示
local function applyNight(desktop, mode, head)
    NightMode.setMode(mode)
    desktop:updateView()
    if mode == "off" then return end
    local from, to = NightMode.window()
    local lines = { head }
    lines[#lines + 1] = T(_("夜间模式将在 %1 开启，%2 关闭"), clock(from), clock(to))
    if (G_reader_settings:readSetting("autowarmth_activate") or 0) ~= 0 then
        lines[#lines + 1] = _("KOReader 自带的自动夜间模式也开着，两者会互相覆盖，建议关掉其中一个。")
    end
    Toast:new{ text = table.concat(lines, "\n\n") }:show()
end

--- 依次选夜间开始、结束时间。
---@param desktop table
local function pickSchedule(desktop)
    local conf = MoonSettings.get("features.nightmode")
    local function fmt2(v) return string.format("%02d", v) end
    local function pick(title, minute, ok_text, done)
        Spin:new{
            title = title, ok_text = ok_text,
            fields = {
                { value = math.floor(minute / 60), min = 0, max = 23, wrap = true, label = _("时"), format = fmt2 },
                { value = minute % 60, min = 0, max = 59, wrap = true, label = _("分"), format = fmt2 },
            },
            callback = function(hour, min) done(hour * 60 + min) end,
        }:show()
    end
    pick(_("夜间开始"), conf.auto_night_from, _("下一步"), function(from)
        pick(_("夜间结束"), conf.auto_night_to, _("保存"), function(to)
            if to == from then
                Toast:new{ text = _("开始和结束时间相同，没有夜间时段"), timeout = 3 }:show()
                return
            end
            conf.auto_night_from, conf.auto_night_to = from, to
            applyNight(desktop, "schedule")
        end)
    end)
end

--- 定位成功才切到日出日落；失败保持原模式。
--- 天气任务若停在等网状态，结果要等它续跑才来：提示到点自己收起，不挂着。
---@param desktop table
local function pickSun(desktop)
    local loading = Toast:new{ text = _("正在定位…"), timeout = 30 }
    loading:show()
    NightMode.locate(function(ok, city)
        loading:close()
        if not ok then
            Toast:new{ text = _("定位失败，请联网后重试"), timeout = 3 }:show()
            return
        end
        applyNight(desktop, "sun", T(_("已定位：%1"), city or _("当前位置")))
    end)
end

---@param desktop table
---@return fun(width: number): table
local function nightRow(desktop)
    return function(iw)
        local mode = MoonSettings.get("features.nightmode").auto_night
        local from, to = NightMode.window()
        return Row.widget({
            width = iw, chevron = true,
            kind = "nav", icon = "dark_mode", title = _("自动夜间模式"),
            subtitle = _("定时或按日出日落切换；中途手动切换不会被立刻改回"),
            status = from and clock(from) .. "–" .. clock(to) or _("关"), status_on = from ~= nil,
            callback = function()
                List:new{
                    title = _("自动夜间模式"),
                    items = {
                        { value = "off", text = _("关闭") },
                        { value = "schedule", text = _("定时") },
                        { value = "sun", text = _("日出日落") },
                    },
                    current = mode or "off",
                    centered = true,
                    on_select = function(value)
                        if value == "schedule" then return pickSchedule(desktop) end
                        if value == "sun" then return pickSun(desktop) end
                        applyNight(desktop, "off")
                    end,
                }:show()
            end,
        })
    end
end

-- 与 Device:ambientBrightnessLevel() 的 0..4 一一对应。
local LEVEL_NAMES = { _("黑暗"), _("昏暗"), _("中性"), _("明亮"), _("刺眼") }
-- 与 NightMode.PERIOD_STARTS 一一对应。
local PERIOD_NAMES = { _("凌晨"), _("清晨"), _("上午"), _("中午"), _("下午"), _("傍晚"), _("晚上"), _("深夜") }

---@param percent number
---@return string
local function lightLabel(percent)
    return percent > 0 and percent .. "%" or _("关灯")
end

--- 自动亮度菜单：开关 + 各档（有传感器）或各时段（无传感器）亮度。
--- 菜单常开，改一项就地刷新，连调多个时段不用反复进出。
---@param desktop table
local function openLight(desktop)
    local conf = MoonSettings.get("features.nightmode")
    local list, items
    local function changed()
        desktop:updateView()
        list:setItems(items())
    end
    items = function()
        local out = { { text = conf.auto_light and _("关闭") or _("开启"), keep_open = true, callback = function()
            NightMode.setLight(not conf.auto_light)
            changed()
        end } }
        local function add(name, tbl, key)
            out[#out + 1] = { text = name, mandatory = lightLabel(tbl[key]), keep_open = true, callback = function()
                Spin:new{
                    title = name,
                    fields = { { value = tbl[key], min = 0, max = 100, step = 5,
                        format = function(v) return v .. "%" end } },
                    callback = function(v)
                        tbl[key] = v
                        MoonSettings.save("features.nightmode")
                        NightMode.applyLight()
                        changed()
                    end,
                }:show()
            end }
        end
        if NightMode.hasSensor() then
            for i, name in ipairs(LEVEL_NAMES) do add(name, conf.auto_light_levels, i) end
        else
            for i, name in ipairs(PERIOD_NAMES) do
                add(name .. " " .. clock(NightMode.PERIOD_STARTS[i]), conf.auto_light_periods, i)
            end
        end
        return out
    end
    list = List:new{ title = _("自动亮度"), items = items(), centered = true }
    list:show()
end

---@param desktop table
---@return (fun(width: number): table)|nil
local function lightRow(desktop)
    if not Device:hasFrontlight() then return nil end
    return function(iw)
        local on = MoonSettings.get("features.nightmode").auto_light
        return Row.widget({
            width = iw, chevron = true,
            kind = "nav", icon = "brightness_auto", title = _("自动亮度"),
            subtitle = NightMode.hasSensor() and _("按环境光调节；手动调亮度会关闭自动亮度")
                or _("按时段和天气调节；手动调亮度会关闭自动亮度"),
            status = on and _("开") or _("关"), status_on = on,
            callback = function() openLight(desktop) end,
        })
    end
end

--- 自动夜间一行；有前光时再加自动亮度一行。
---@param desktop table
---@return (fun(width: number): table)[]
function Page.rows(desktop)
    local rows = { nightRow(desktop) }
    local light = lightRow(desktop)
    if light then rows[#rows + 1] = light end
    return rows
end

return Page
