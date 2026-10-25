--[[--
「运行状态」页：整机内存与 CPU，加上按内存或 CPU 从高到低的进程列表。

采样器和排序方式挂在桌面实例上（`desktop.monitor`）。页面每 10 秒由叠层重算一次，
翻页 / 切换排序也会重算，所以距上次采样不足 1 秒就复用结果，避免 CPU 差值被一个极短的窗口放大。

@module koplugin.book.features.monitor.page
--]]

local Procs = require("features.monitor.procs")
local Row = require("ui.themes.widgets.row")
local _ = require("gettext")
local T = require("ffi/util").template

local Page = {}

local TOP = 15 -- 列表最多显示的进程数

-- Kindle 系统进程的用途，没收录的按原名显示
local KINDLE = {
    KPPMainApp = "Kindle 阅读器框架",
    java = "Kindle 原生阅读器与主页",
    pillowd = "Kindle 界面服务",
    JunoStatusBarDriver = "Kindle 状态栏",
    awesome = "Kindle 窗口管理",
    Xorg = "Kindle 显示服务",
    weblabdaemon = "Kindle 实验开关服务",
    KindleDocumentIndexerService = "Kindle 书籍索引",
    KindleSyncService = "Kindle 云同步",
    blanket = "Kindle 屏保与锁屏",
    kb = "Kindle 键盘服务",
    fastmetrics = "Kindle 使用统计上报",
    AdmDaemon = "Kindle 应用与下载管理",
    localization_assetsd = "Kindle 本地化资源",
    ["tizen-mtp"] = "USB 文件传输 (MTP)",
    registrationd = "Kindle 账号注册服务",
    tzd = "Kindle 时区服务",
    powerd = "Kindle 电源管理",
    acsbtfd = "Kindle 蓝牙服务",
}

--- 「用途 (原名)」；没收录的只显示原名。
local function label(name)
    if name == "KOReader (luajit)" then return _("KOReader（含月读）") .. " (luajit)" end
    local desc = KINDLE[name]
    return desc and (_(desc) .. " (" .. name .. ")") or name
end

local function size(kb)
    return require("util").getFriendlySize(kb * 1024) or tostring(kb) .. " KB"
end

local function percent(value)
    return value and string.format("%.1f%%", value) or "—"
end

---@param desktop BookDesktop
---@return table
local function state(desktop)
    if not desktop.monitor then desktop.monitor = { procs = Procs.new(), sort = "mem", at = 0 } end
    return desktop.monitor
end

---@param desktop BookDesktop
function Page.toggleSort(desktop)
    local s = state(desktop)
    s.sort = s.sort == "mem" and "cpu" or "mem"
    if desktop.settings_overlay then desktop.settings_overlay:updateView() end
end

---@param title string
---@param status string
---@return fun(iw: number): table
local function infoRow(title, status)
    return function(iw)
        return Row.widget({ width = iw, chevron = false, title = title, status = status })
    end
end

--- KOReader 自带的「设备状态警报 → 高内存用量」（ReaderDeviceStatus，注册为 ui.devicestatus）。
--- 阈值是 KOReader 自身进程的常驻内存，不是整机可用内存；设置键沿用它的 `device_status_memory_*`，
--- 两边改的是同一份。阈值与间隔在模块实例里有缓存，所以要同步改实例字段。
---@param desktop BookDesktop
---@return BookThemeSection|nil
local function alertSection(desktop)
    local ds = desktop.plugin.ui.devicestatus
    if not ds or not ds.checkHighMemoryUsage then return nil end
    local settings = G_reader_settings
    local alarm_on = settings:isTrue("device_status_memory_alarm")

    local function toggleRow(title, subtitle, key, enabled, after)
        return function(iw)
            local on = settings:isTrue(key)
            return Row.widget({
                width = iw, chevron = false, kind = "toggle", title = title, subtitle = subtitle,
                status = on and _("开") or _("关"), status_on = on, enabled = enabled,
                callback = function()
                    settings:flipNilOrFalse(key)
                    if after then after() end
                    desktop.settings_overlay:updateView()
                end,
            })
        end
    end
    local function spinRow(title, status, spin, apply)
        return function(iw)
            return Row.widget({
                width = iw, kind = "nav", title = title, status = status, enabled = alarm_on,
                callback = function()
                    require("ui.themes.widgets.spin"):new{
                        title = title,
                        fields = { spin },
                        callback = function(value)
                            apply(value)
                            desktop.settings_overlay:updateView()
                        end,
                    }:show()
                end,
            })
        end
    end

    return {
        title = _("KOReader 内存警报"),
        rows = {
            toggleRow(_("高内存用量警报"), _("KOReader 自身内存超过阈值时提醒"), "device_status_memory_alarm", true, function()
                if settings:isTrue("device_status_memory_alarm") then
                    ds:startMemoryChecker(true)
                else
                    ds:stopMemoryChecker()
                end
            end),
            spinRow(_("内存阈值"), ds.memory_threshold .. " MB",
                { value = ds.memory_threshold, min = 20, max = 500, step = 5, label = "MB" },
                function(value)
                    ds.memory_threshold = value
                    settings:saveSetting("device_status_memory_threshold", value)
                end),
            spinRow(_("检查间隔"), T(_("%1 分钟"), ds.memory_interval_m),
                { value = ds.memory_interval_m, min = 1, max = 60, label = _("分钟") },
                function(value)
                    ds.memory_interval_m = value
                    settings:saveSetting("device_status_memory_interval_minutes", value)
                    ds:stopMemoryChecker()
                    ds:startMemoryChecker(true)
                end),
            toggleRow(_("自动重启"), _("超过阈值且正在阅读时直接重启，否则弹窗询问"),
                "device_status_memory_auto_restart",
                alarm_on and require("device"):canRestart()),
        },
    }
end

---@param desktop BookDesktop
---@return BookThemeSection[]
function Page.sections(desktop)
    local s = state(desktop)
    if os.time() - s.at >= 1 then
        s.sample, s.at = s.procs:sample(), os.time()
    end
    local sample = s.sample
    if not sample then
        return { { title = _("运行状态"), rows = { infoRow(_("此设备不支持"), "") } } }
    end

    local used = sample.mem_total - sample.mem_avail
    local procs = {}
    for i, p in ipairs(sample.procs) do procs[i] = p end
    Procs.sort(procs, s.sort)

    local rows = {}
    for i = 1, math.min(TOP, #procs) do
        local p = procs[i]
        local first, second = size(p.rss), percent(p.cpu)
        if s.sort == "cpu" then first, second = second, first end
        rows[#rows + 1] = infoRow(label(p.name), first .. "  " .. second)
    end
    local sections = {
        {
            title = _("整机"),
            rows = {
                infoRow(_("内存"), T(_("已用 %1 / 共 %2"), size(used), size(sample.mem_total))),
                infoRow(_("CPU"), percent(sample.cpu)),
            },
        },
    }
    sections[#sections + 1] = alertSection(desktop)
    sections[#sections + 1] = {
        title = s.sort == "cpu" and _("进程（按 CPU 从高到低）") or _("进程（按内存从高到低）"),
        rows = rows,
    }
    return sections
end

return Page
