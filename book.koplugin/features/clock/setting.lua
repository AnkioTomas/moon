--[[--
时间与时区配置键（settings/clock.lua）与设置入口：根页系统组「时间与日期」。

@module koplugin.book.features.clock.setting
--]]

local _ = require("gettext")

local Setting = {}

-- timezone：POSIX TZ 串，"" = 跟随系统。ntp_last：上次校时成功的 unix 秒，0 = 从未。
Setting.defaults = {
    timezone = "",
    ntp_auto = false,
    ntp_server = "ntp.aliyun.com",
    ntp_last = 0,
}

---@param desktop BookDesktop
---@return BookSettingEntry[]
function Setting.entries(desktop)
    return {
        {
            id = "main",
            group = "system",
            order = 15,
            icon = "schedule",
            title = _("时间与日期"),
            subtitle = _("时区、系统时间与网络校时"),
            status = os.date("%H:%M"),
            status_on = true,
            page = {
                title = _("时间与日期"),
                sections = function() return require("features.clock.page").sections(desktop) end,
            },
        },
    }
end

return Setting
