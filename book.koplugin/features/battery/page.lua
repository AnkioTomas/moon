--[[--
「电池」页：健康度、循环、容量和瞬时电气量。

没有设计容量时不显示假的百分比，只说明不支持，并给出节点日志：
复制后扫反馈群二维码发给开发者。日志正文是给开发者看的原始节点，不走翻译。

@module koplugin.book.features.battery.page
--]]

local Probe = require("features.battery.probe")
local Row = require("ui.themes.widgets.row")
local _ = require("gettext")

local Page = {}

-- 与维护页「关于」里的 Bug 反馈群是同一个群。
local BUG_GROUP_URL = "https://qm.qq.com/q/btmL9F4Cl2"

local function infoRow(title, status)
    return function(iw)
        return Row.widget({ width = iw, chevron = false, title = title, status = status })
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
                        text = BUG_GROUP_URL,
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
---@return BookThemeSection[]
local function unsupported(report)
    return {
        {
            title = _("此设备不支持"),
            rows = {
                function(iw)
                    return Row.widget({
                        width = iw, chevron = false,
                        title = _("健康度"), status = _("不支持"),
                        subtitle = _("内核没有设计容量，算不出来。"),
                    })
                end,
                function(iw)
                    return Row.widget({
                        width = iw,
                        kind = "nav",
                        title = _("复制日志发给开发者"),
                        subtitle = _("点开后复制日志，再扫码发到反馈群。复制不了就截图。"),
                        callback = function() Page.showReport(report) end,
                    })
                end,
            },
        },
    }
end

---@return BookThemeSection[]
function Page.sections()
    local result = Probe.read()
    if not result.supported then return unsupported(result.report) end
    local row = result.reading
    local rows = {
        infoRow(_("健康度"), string.format("%.1f%%", row.health_pct)),
    }
    if row.cycles then
        rows[#rows + 1] = infoRow(_("循环次数"), string.format("%.0f", row.cycles))
    end
    local function add(title, text)
        if text then rows[#rows + 1] = infoRow(title, text) end
    end
    add(_("现在充满"), row.charge_full_mah and string.format("%.0f mAh", row.charge_full_mah))
    add(_("设计容量"), row.charge_design_mah and string.format("%.0f mAh", row.charge_design_mah))
    add(_("剩余容量"), row.charge_now_mah and string.format("%.0f mAh", row.charge_now_mah))
    add(_("电量"), row.capacity and string.format("%.0f%%", row.capacity))
    add(_("状态"), statusText(row.status))
    add(_("供电状态"), supplyText(row.health))
    add(_("温度"), row.temp_c and string.format("%.1f °C", row.temp_c))
    add(_("电压"), row.voltage_v and string.format("%.3f V", row.voltage_v))
    add(_("电流"), row.current_ma and string.format("%.0f mA", row.current_ma))
    return { { title = _("电池"), rows = rows } }
end

return Page
