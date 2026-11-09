--[[--
电池读数：健康度 / 容量快照 + 用法统计（每小时耗电、预估可用）。
整页挂在「我的设备 → 本机 → 电池」。

健康度仍要设计容量；没有就标明不支持并给节点日志。
用法统计只看电量百分比变化，不支持健康度的设备也能看。

@module koplugin.book.features.battery.page
--]]

local Probe = require("features.battery.probe")
local Stats = require("features.battery.stats")
local Row = require("ui.themes.widgets.row")
local _ = require("gettext")

local Page = {}

local function infoRow(icon, title, status, subtitle)
    return function(iw)
        return Row.widget({
            width = iw, chevron = false, icon = icon, title = title, status = status, subtitle = subtitle,
        })
    end
end

---@param raw string|nil
---@return string|nil
local function statusText(raw)
    if raw == "Discharging" then return _("放电中") end
    if raw == "Charging" then return _("充电中") end
    if raw == "Full" then return _("已充满") end
    if raw == "Not charging" then return _("未充电") end
    if raw == "Unknown" then return _("未知") end
    return raw
end

---@param raw string|nil
---@return string|nil
local function supplyText(raw)
    if raw == "Good" then return _("正常") end
    if raw == "Overheat" then return _("过热") end
    if raw == "Cold" then return _("过冷") end
    if raw == "Dead" then return _("损坏") end
    if raw == "Unknown" then return _("未知") end
    return raw
end

--- 弹出节点日志。复制失败时正文还在，用户可以截图。
---@param report string
function Page.showReport(report)
    local Device = require("device")
    local TextViewer = require("ui.themes.widgets.text_viewer")
    local Toast = require("ui.themes.widgets.toast")
    local QR = require("ui.themes.widgets.qr")
    local dialog
    dialog = TextViewer:new{
        title = _("电池节点日志"),
        text = _("把这份日志发给开发者：点「复制」，再点「反馈群」，扫码进群后粘贴。复制不了就截图。")
            .. "\n\n" .. report,
        buttons = {
            { text = _("关闭"), callback = function() dialog:close() end },
            {
                text = _("反馈群"),
                callback = function()
                    QR:new{
                        title = _("Bug 反馈群"),
                        text = require("desktop.pages.setting.device").BUG_GROUP_URL,
                        caption = _("扫码进群，把刚复制的日志贴进去"),
                    }:show()
                end,
            },
            {
                text = _("复制"),
                variant = "primary",
                callback = function()
                    if not Device:hasClipboard() then
                        Toast:new{ text = _("这台设备复制不了，请截图"), timeout = 3 }:show()
                        return
                    end
                    Device.input.setClipboardText(report)
                    Toast:new{ text = _("已复制"), timeout = 2 }:show()
                end,
            },
        },
    }
    dialog:show()
end

---@param report string
---@return (fun(iw: number): table)[]
local function unsupportedRows(report)
    return {
        infoRow("battery_android_full", _("健康度"), _("不支持"), _("读不到设计容量，算不出来。")),
        function(iw)
            return Row.widget({
                width = iw, kind = "nav", icon = "bug_report",
                title = _("复制日志发给开发者"),
                subtitle = _("点开后复制日志，再扫码发到反馈群。复制不了就截图。"),
                callback = function() Page.showReport(report) end,
            })
        end,
    }
end

---@param row table
---@return (fun(iw: number): table)[]
local function hardwareRows(row)
    local rows = {
        infoRow("battery_android_full", _("健康度"),
            string.format("%.1f%%", row.health_pct),
            _("按电量计容量估算，仅供参考。")),
    }
    if row.cycles then
        rows[#rows + 1] = infoRow("autorenew", _("循环次数"), string.format("%.0f", row.cycles))
    end
    local function add(icon, title, text)
        if text then rows[#rows + 1] = infoRow(icon, title, text) end
    end
    add("battery_full", _("现在充满"), row.charge_full_mah and string.format("%.0f mAh", row.charge_full_mah))
    add("memory", _("设计容量"), row.charge_design_mah and string.format("%.0f mAh", row.charge_design_mah))
    add("battery_5_bar", _("剩余容量"), row.charge_now_mah and string.format("%.0f mAh", row.charge_now_mah))
    add("battery_android_full", _("电量"), row.capacity and string.format("%.0f%%", row.capacity))
    add("power_settings_new", _("状态"), statusText(row.status))
    add("electrical_services", _("供电状态"), supplyText(row.health))
    add("device_thermostat", _("温度"), row.temp_c and string.format("%.1f °C", row.temp_c))
    add("bolt", _("电压"), row.voltage_v and string.format("%.3f V", row.voltage_v))
    add("electric_bolt", _("电流"), row.current_ma and string.format("%.0f mA", row.current_ma))
    return rows
end

--- 一组用法：累计时长 / 消耗或充电 / 每小时 / 预估；调用方用 title 做分节标题。
---@param block table
---@param consumed_title string
---@param estimate_title string
---@return (fun(iw: number): table)[]
local function usageRows(block, consumed_title, estimate_title)
    return {
        infoRow("schedule", _("累计时长"), Stats.formatDuration(block.time)),
        infoRow("battery_android_full", consumed_title, block.consumed),
        infoRow("speed", _("每小时电量变化"), block.rate),
        infoRow("timelapse", estimate_title, block.remaining),
    }
end

---@param desktop BookDesktop|nil
---@return fun(iw: number): table
local function resetRow(desktop)
    return function(iw)
        return Row.widget({
            width = iw, kind = "action", icon = "restart_alt",
            title = _("重置用法统计"),
            subtitle = _("清空累计，从现在重新采样"),
            callback = function()
                require("ui.themes.widgets.confirm"):new{
                    text = _("清空用法统计？健康度与容量读数不受影响。"),
                    ok_text = _("清空"),
                    ok_callback = function()
                        Stats.reset()
                        if desktop and desktop.settings_overlay then
                            desktop.settings_overlay:updateView()
                        end
                    end,
                }:show()
            end,
        })
    end
end

---@param desktop BookDesktop|nil
---@return BookThemeSection[]
local function statsSections(desktop)
    local sum = Stats.summary()
    return {
        {
            title = _("用法统计"),
            rows = {
                infoRow("info", _("说明"), nil, _("按电量百分比变化估算，高电量段可能不准。")),
            },
        },
        { title = _("上次充电以来的唤醒"), rows = usageRows(sum.awake, _("已消耗"), _("预计可用时长")) },
        { title = _("上次充电以来的休眠"), rows = usageRows(sum.sleeping, _("已消耗"), _("预计可用时长")) },
        { title = _("上次充电"), rows = usageRows(sum.charging_usage, _("已充电"), _("预计充满用时")) },
        { title = _("自从上次充电"), rows = usageRows(sum.discharging, _("已消耗"), _("预计可用时长")) },
        { rows = { resetRow(desktop) } },
    }
end

---@param desktop BookDesktop|nil
---@return BookThemeSection[]
function Page.sections(desktop)
    local result = Probe.read()
    local sections = {}
    if result.supported then
        sections[#sections + 1] = { title = _("电池"), rows = hardwareRows(result.reading) }
    else
        sections[#sections + 1] = { title = _("此设备不支持"), rows = unsupportedRows(result.report) }
    end
    for _idx, section in ipairs(statsSections(desktop)) do
        sections[#sections + 1] = section
    end
    return sections
end

return Page
