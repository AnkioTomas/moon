--[[--
自动夜间 / 自动亮度配置键（settings/nightmode.lua）与设置：往桌面「屏幕」页追加「夜间与亮度」分节。

@module koplugin.book.features.nightmode.setting
--]]

local _ = require("gettext")

local Setting = {}

-- auto_night：off / schedule / sun；时间是当天分钟数。
-- 亮度百分比，0 = 关灯。有光线传感器按 ambientBrightnessLevel 0..4 查 levels，否则按 NightMode.PERIOD_STARTS 时段查 periods。
-- 昏暗最需要补光；黑暗眼睛已适应，低一档即可；中性少量；明亮起墨水屏不需要前光。
-- 时段：凌晨 清晨 上午 中午 下午 傍晚 晚上 深夜。
Setting.defaults = {
    auto_night = "off", auto_night_from = 22 * 60, auto_night_to = 7 * 60,
    auto_light = false, auto_light_levels = { 25, 50, 35, 0, 0 },
    auto_light_periods = { 5, 12, 22, 30, 27, 18, 10, 5 },
}

-- sun 模式按天气城市定位后才写：纬度、经度、当地时区分钟偏移（缺省用设备时区）。
Setting.keys = { "auto_night_lat", "auto_night_lon", "auto_night_tz" }

---@param desktop BookDesktop
---@return BookSettingEntry[]
function Setting.entries(desktop)
    return {
        {
            parent = "display",
            order = 30,
            sections = function()
                return { { title = _("夜间与亮度"), rows = require("features.nightmode.page").rows(desktop) } }
            end,
        },
    }
end

return Setting
