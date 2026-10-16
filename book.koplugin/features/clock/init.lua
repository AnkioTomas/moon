--[[--
时间与时区：时区设置、手动改系统时间、NTP 自动校时。

时区只改 KOReader 进程的 `TZ`（POSIX 串，自带夏令时规则，不依赖设备上的 zoneinfo），
`tzset` 后 os.date / os.time 立即换算；子进程（`date -s`、校时）继承同一个 TZ，
所以按本地时间设系统时间与这里的显示一致。空串 = 跟随系统（还原启动时的 TZ）。

校时：`Desktop:activate`（打开桌面、唤醒）调 `autoSync`，没联网就记着、等 `onNetworkConnected` 补一次。
DNS 与 UDP 都会阻塞，查询放 workers.job 子进程；同一时刻只有一个在飞。
系统时间经 `Device:setDateTime`：KOReader 认为设备不能改时间时，改时间相关的功能都不出现。

@module koplugin.book.features.clock
--]]

require("l10n").apply()

local ffi = require("ffi")
local MoonSettings = require("utils.settings")
local _ = require("gettext")
local T = require("ffi/util").template

require("ffi/posix_h")
ffi.cdef("void tzset(void);")

local Clock = {
    ---@type table|nil 在飞的校时子进程
    _job = nil,
    --- 进入桌面时没联网，等联网补一次。
    _pending = false,
}

--- 进程启动时的 TZ；「跟随系统」还原它。KOReader 没有自己的时区设置，时间全按系统 TZ 换算。
local SYSTEM_TZ = os.getenv("TZ")

--- strftime 的 %z（"+0800" / "-0330"）→ "UTC+8" / "UTC−3:30"。
---@param z string
---@return string
local function utcLabel(z)
    local sign, hh, mm = z:match("^([+-])(%d%d)(%d%d)$")
    if not sign then return "UTC" end
    local hours, minutes = tonumber(hh), tonumber(mm)
    if hours == 0 and minutes == 0 then return "UTC" end
    local text = "UTC" .. (sign == "-" and "−" or "+") .. hours
    return minutes > 0 and text .. string.format(":%02d", minutes) or text
end

--- 系统时区偏移，在本模块改 TZ 之前取。
local SYSTEM_UTC = utcLabel(os.date("%z") --[[@as string]])
local QUERY_TIMEOUT = 5
--- 偏差小于这个秒数不改系统时间。
local TOLERANCE = 1
--- 自动校时的间隔：进桌面很频繁（每次从阅读页回来、每次唤醒），校一次管半天。
local AUTO_INTERVAL = 6 * 3600

--- 时区选项：tz 是 POSIX TZ 串，"" = 跟随系统（显示名见 zoneText）。同一偏移只列一个，城市名帮用户认。
---@type { tz: string, text: string|nil }[]
Clock.TIMEZONES = {
    { tz = "" },
    { tz = "HST10", text = _("UTC−10 檀香山") },
    { tz = "AKST9AKDT,M3.2.0,M11.1.0", text = _("UTC−9 安克雷奇") },
    { tz = "PST8PDT,M3.2.0,M11.1.0", text = _("UTC−8 洛杉矶、温哥华") },
    { tz = "MST7MDT,M3.2.0,M11.1.0", text = _("UTC−7 丹佛") },
    { tz = "CST6CDT,M3.2.0,M11.1.0", text = _("UTC−6 芝加哥") },
    { tz = "EST5EDT,M3.2.0,M11.1.0", text = _("UTC−5 纽约、多伦多") },
    { tz = "<-03>3", text = _("UTC−3 圣保罗") },
    { tz = "UTC0", text = _("UTC 协调世界时") },
    { tz = "GMT0BST,M3.5.0/1,M10.5.0", text = _("UTC+0 伦敦") },
    { tz = "CET-1CEST,M3.5.0,M10.5.0/3", text = _("UTC+1 柏林、巴黎") },
    { tz = "EET-2EEST,M3.5.0/3,M10.5.0/4", text = _("UTC+2 雅典、基辅") },
    { tz = "MSK-3", text = _("UTC+3 莫斯科") },
    { tz = "<+04>-4", text = _("UTC+4 迪拜") },
    { tz = "IST-5:30", text = _("UTC+5:30 新德里") },
    { tz = "<+07>-7", text = _("UTC+7 曼谷、雅加达") },
    { tz = "CST-8", text = _("UTC+8 北京、香港、台北、新加坡") },
    { tz = "JST-9", text = _("UTC+9 东京、首尔") },
    { tz = "AEST-10AEDT,M10.1.0,M4.1.0/3", text = _("UTC+10 悉尼") },
    { tz = "NZST-12NZDT,M9.5.0,M4.1.0/3", text = _("UTC+12 奥克兰") },
}

---@return table
local function conf()
    return MoonSettings.get("features.clock")
end

--- 选项的显示名：跟随系统带上系统的实际偏移。
---@param zone { tz: string, text: string|nil }
---@return string
function Clock.zoneText(zone)
    return zone.text or T(_("跟随系统（%1）"), SYSTEM_UTC)
end

--- 当前时区的显示名；设置里是列表外的串时原样显示。
---@return string
function Clock.timezoneLabel()
    local tz = conf().timezone
    for _idx, zone in ipairs(Clock.TIMEZONES) do
        if zone.tz == tz then return Clock.zoneText(zone) end
    end
    return tz
end

--- 把设置里的时区应用到本进程。
function Clock.applyTimezone()
    local tz = conf().timezone
    if tz == "" then tz = SYSTEM_TZ end
    if tz then
        ffi.C.setenv("TZ", tz, 1)
    else
        ffi.C.unsetenv("TZ")
    end
    ffi.C.tzset()
end

---@param tz string
function Clock.setTimezone(tz)
    conf().timezone = tz
    MoonSettings.save("features.clock")
    Clock.applyTimezone()
    local UIManager = require("ui/uimanager")
    UIManager:broadcastEvent(require("ui/event"):new("TimeFormatChanged"))
end

--- KOReader 能改这台设备的系统时间（不带参数调用即探测，见各设备的 setDateTime）。
---@return boolean
function Clock.canSetTime()
    return require("device"):setDateTime() == true
end

--- 按本地时间设系统时间。
---@param epoch number
---@return boolean ok
function Clock.setTime(epoch)
    local t = os.date("*t", math.floor(epoch + 0.5))
    return require("device"):setDateTime(t.year, t.month, t.day, t.hour, t.min, t.sec) == true
end

--- 校时一次：偏差超过 TOLERANCE 才改系统时间。已有在飞的直接返回 false（不回调）。
---@param cb fun(ok: boolean, offset: number|nil, err: string|nil)|nil offset 为服务器减本机（秒）
---@return boolean started
function Clock.sync(cb)
    if Clock._job then return false end
    local server = conf().ntp_server
    local function finish(ok, offset, err)
        Clock._job = nil
        if not ok then require("utils.log").warn("clock ntp sync failed", server, err) end
        if cb then cb(ok, offset, err) end
    end
    Clock._job = require("workers.job").run(function()
        return require("features.clock.ntp").query(server, QUERY_TIMEOUT)
    end, {
        name = "clock.ntp",
        kind = "light",
        timeout = QUERY_TIMEOUT * 3,
        on_done = function(result)
            if not result.offset then return finish(false, nil, result.err) end
            if math.abs(result.offset) >= TOLERANCE
                    and not Clock.setTime(require("socket").gettime() + result.offset) then
                return finish(false, result.offset, "set time failed")
            end
            local settings = conf()
            settings.ntp_last = os.time()
            MoonSettings.save("features.clock")
            finish(true, result.offset)
        end,
        on_failed = function(err) finish(false, nil, err) end,
    })
    return true
end

--- 进入桌面时静默校时；没联网等联网再补。上次成功在 AUTO_INTERVAL 内就跳过（abs：时间被往回改过也算）。
function Clock.autoSync()
    local settings = conf()
    if not settings.ntp_auto or math.abs(os.time() - settings.ntp_last) < AUTO_INTERVAL
            or not Clock.canSetTime() then
        return
    end
    if not require("ui/network/manager"):isConnected() then
        Clock._pending = true
        return
    end
    Clock._pending = false
    Clock.sync()
end

---@param _plugin BookPlugin
function Clock.onCreate(_plugin)
    Clock.applyTimezone()
end

---@param _plugin BookPlugin
function Clock.onNetworkConnected(_plugin)
    if Clock._pending then Clock.autoSync() end
end

---@param _plugin BookPlugin
function Clock.onExit(_plugin)
    if Clock._job then Clock._job:cancel() end
    Clock._job = nil
end

-- 扩展点登记（features 加载器 require 本模块时执行一次；见 utils/extension.lua）。
require("utils.extension").add("desktop.activated", function() Clock.autoSync() end)

return Clock
