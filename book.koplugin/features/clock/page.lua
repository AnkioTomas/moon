--[[--
「时间与日期」设置页：时区；设备能改系统时间时再给手动设置与 NTP 校时。

@module koplugin.book.features.clock.page
--]]

local Clock = require("features.clock")
local Input = require("ui.themes.widgets.input")
local List = require("ui.themes.widgets.list")
local MoonSettings = require("utils.settings")
local Row = require("ui.themes.widgets.row")
local Spin = require("ui.themes.widgets.spin")
local Toast = require("ui.themes.widgets.toast")
local Text = require("utils.text")
local _ = require("gettext")
local T = require("ffi/util").template

local Page = {}

---@param desktop table
---@return fun(width: number): table
local function timezoneRow(desktop)
    return function(iw)
        return Row.widget({
            width = iw, chevron = true,
            kind = "nav", icon = "public", title = _("时区"),
            subtitle = _("只影响月读与 KOReader 显示的时间"),
            status = Clock.timezoneLabel(), status_on = true,
            callback = function()
                local items = {}
                for _idx, zone in ipairs(Clock.TIMEZONES) do
                    items[#items + 1] = { value = zone.tz, text = Clock.zoneText(zone) }
                end
                List:new{
                    title = _("时区"),
                    items = items,
                    current = MoonSettings.get("features.clock").timezone,
                    on_select = function(tz)
                        Clock.setTimezone(tz)
                        desktop:updateView()
                    end,
                }:show()
            end,
        })
    end
end

---@param desktop table
---@return fun(width: number): table
local function timeRow(desktop)
    return function(iw)
        return Row.widget({
            width = iw, chevron = true,
            kind = "nav", icon = "edit_calendar", title = _("日期和时间"),
            status = os.date("%Y-%m-%d %H:%M"), status_on = true,
            callback = function()
                local now = os.date("*t")
                local function fmt2(v) return string.format("%02d", v) end
                Spin:new{
                    title = _("日期和时间"),
                    ok_text = _("保存"),
                    fields = {
                        { value = now.year, min = 1970, max = 2099, label = _("年") },
                        { value = now.month, min = 1, max = 12, wrap = true, label = _("月"), format = fmt2 },
                        { value = now.day, min = 1, max = 31, wrap = true, label = _("日"), format = fmt2 },
                        { value = now.hour, min = 0, max = 23, wrap = true, label = _("时"), format = fmt2 },
                        { value = now.min, min = 0, max = 59, wrap = true, label = _("分"), format = fmt2 },
                    },
                    callback = function(year, month, day, hour, min)
                        -- 2 月 31 日之类由 os.time 顺延到下月。
                        local epoch = os.time({ year = year, month = month, day = day, hour = hour, min = min, sec = 0 })
                        if not Clock.setTime(epoch) then
                            Toast:new{ text = _("无法设置系统时间"), timeout = 3 }:show()
                        end
                        desktop:updateView()
                    end,
                }:show()
            end,
        })
    end
end

---@param desktop table
---@return fun(width: number): table
local function autoRow(desktop)
    return function(iw)
        local settings = MoonSettings.get("features.clock")
        local on = settings.ntp_auto
        return Row.widget({
            width = iw, chevron = false,
            kind = "toggle", icon = "update", title = _("自动校时"),
            subtitle = _("每次进入桌面时联网向 NTP 服务器校准系统时间"),
            status = on and _("开") or _("关"), status_on = on,
            callback = function()
                settings.ntp_auto = not on
                MoonSettings.save("features.clock")
                desktop:updateView()
                if settings.ntp_auto then Clock.autoSync() end
            end,
        })
    end
end

---@param desktop table
---@return fun(width: number): table
local function serverRow(desktop)
    return function(iw)
        local settings = MoonSettings.get("features.clock")
        return Row.widget({
            width = iw, chevron = true,
            kind = "nav", icon = "dns", title = _("NTP 服务器"),
            status = settings.ntp_server, status_on = true,
            callback = function()
                Input:new{
                    title = _("NTP 服务器"),
                    fields = { { text = settings.ntp_server, hint = "ntp.aliyun.com" } },
                    ok_text = _("保存"),
                    callback = function(value)
                        value = Text.trim(value)
                        if value == "" then return end
                        settings.ntp_server = value
                        MoonSettings.save("features.clock")
                        desktop:updateView()
                    end,
                }:show()
            end,
        })
    end
end

---@param desktop table
---@return fun(width: number): table
local function syncRow(desktop)
    return function(iw)
        local last = MoonSettings.get("features.clock").ntp_last
        return Row.widget({
            width = iw, chevron = false,
            kind = "action", icon = "sync", title = _("立即校时"),
            subtitle = last > 0 and T(_("上次校时：%1"), os.date("%Y-%m-%d %H:%M", last)) or _("从未校时"),
            callback = function()
                if not require("ui/network/manager"):isConnected() then
                    Toast:new{ text = _("网络不可用，请先连接 Wi-Fi"), timeout = 3 }:show()
                    return
                end
                local started = Clock.sync(function(ok, offset)
                    desktop:updateView()
                    local text = ok and T(_("已校时，偏差 %1 秒"), string.format("%.1f", offset))
                        or _("校时失败，请检查 NTP 服务器与网络")
                    Toast:new{ text = text, timeout = 3 }:show()
                end)
                if started then Toast:new{ text = _("正在校时…"), timeout = 2 }:show() end
            end,
        })
    end
end

---@param desktop table
---@return table[]
function Page.sections(desktop)
    local sections = { { title = _("时区"), rows = { timezoneRow(desktop) } } }
    if Clock.canSetTime() then
        sections[#sections + 1] = { title = _("系统时间"), rows = { timeRow(desktop) } }
        sections[#sections + 1] = { title = _("网络校时"),
            rows = { autoRow(desktop), serverRow(desktop), syncRow(desktop) } }
    end
    return sections
end

return Page
