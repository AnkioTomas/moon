--[[-- 锁屏设置项（组合壁纸）。
@module koplugin.book.ui.desktop.settings.lockscreen
--]]

local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local Popup = require("ui.components.popup")
local SettingRow = require("ui.components.settingrow")
local LockScreen = require("lockscreen.init")
local Settings = require("lockscreen.settings")
local Compose = require("lockscreen.compose")
local Background = require("lockscreen.background")
local Components = require("lockscreen.components.base")
local Layout = require("lockscreen.layout")
local Bill = require("lockscreen.components.bill")
local Text = require("utils.text")
local _ = require("gettext")
local T = require("ffi/util").template

local Lockscreen = {}

--- 设置项变更后重建设置页，并重新合成锁屏图。
--- 只有当前配置能离线出图时才直接生成，否则等联网——不然壁纸源拉不到会白跑一次。
---@param desktop table 桌面实例
local function refreshAfterChange(desktop)
    desktop:rebuild()
    --- 合成一次锁屏图并提示结果。
    local function refresh()
        UIManager:show(InfoMessage:new{ text = _("正在生成锁屏图…"), timeout = 2 })
        LockScreen.refresh(function(ok, err)
            UIManager:show(InfoMessage:new{
                text = ok and _("锁屏图已更新")
                    or T(_("生成失败: %1"), tostring(err or "")),
                timeout = 2,
            })
        end, nil, "settings")
    end
    if Compose.plan().offline then
        refresh()
    else
        NetworkMgr:runWhenOnline(refresh)
    end
end

--- 弹输入框编辑锁屏自定义留言，保存后立刻重出图。
---@param desktop table 桌面实例
local function editMessage(desktop)
    local dialog
    dialog = InputDialog:new{
        title = _("自定义留言"),
        input = Settings.customMessage(),
        buttons = {{
            { text = _("取消"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("保存"), is_enter_default = true, callback = function()
                local text = dialog:getInputText()
                UIManager:close(dialog)
                Settings.setCustomMessage(text)
                refreshAfterChange(desktop)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

---@param desktop table
---@return table
function Lockscreen.rows(desktop)
    local enabled = Settings.isCompose()
    local rows = {
        function(iw)
            return SettingRow.build(iw, {
                kind = "toggle", icon = "wallpaper", title = _("替代系统锁屏"),
                status = enabled and _("开") or _("关"), status_on = enabled,
                callback = function()
                    Settings.setMode(enabled and "ko" or "compose")
                    if enabled then
                        desktop:rebuild()
                    else
                        refreshAfterChange(desktop)
                    end
                end,
            })
        end,
    }
    if not enabled then
        return rows
    end

    local plan = Compose.plan()
    local component_config = plan.component
    local component = component_config.id
    if component_config.uses_background ~= false then
        rows[#rows + 1] = function(iw)
            local background = plan.background_mode
            return SettingRow.build(iw, {
                kind = "nav", icon = "image", title = _("背景"),
                status = Background.label(background),
                subtitle = Background.hint(background),
                callback = function()
                    Popup.list{
                        title = _("背景"),
                        items = Background.options(),
                        current = background, choice_icons = true, centered = true,
                        on_select = function(value)
                            if not value or value == background then return end
                            Settings.setBackgroundMode(value)
                            refreshAfterChange(desktop)
                        end,
                    }
                end,
            })
        end
    end

    rows[#rows + 1] = function(iw)
        local label = _("无")
        for _, item in ipairs(Components.options()) do
            if item.value == component then
                label = item.text
                break
            end
        end
        return SettingRow.build(iw, {
            kind = "nav", icon = "widgets", title = _("主体组件"),
            status = label,
            callback = function()
                Popup.list{
                    title = _("主体组件"),
                    items = Components.options(),
                    current = component, choice_icons = true, centered = true,
                    on_select = function(value)
                        if not value or value == component then return end
                        Settings.setComponent(value)
                        refreshAfterChange(desktop)
                    end,
                }
            end,
        })
    end

    if component_config and component_config.supports_position ~= false then
        rows[#rows + 1] = function(iw)
            local position = plan.position
            return SettingRow.build(iw, {
                kind = "nav", icon = "open_in_full", title = _("主体位置"),
                status = Layout.label(position),
                callback = function()
                    Popup.list{
                        title = _("主体位置"), items = Layout.options(), current = position,
                        choice_icons = true, centered = true,
                        on_select = function(value)
                            if not value or value == position then return end
                            Settings.setPosition(value)
                            refreshAfterChange(desktop)
                        end,
                    }
                end,
            })
        end

        if plan.supports_narrow then
            rows[#rows + 1] = function(iw)
                local wide = plan.wide
                return SettingRow.build(iw, {
                    kind = "nav", icon = "aspect_ratio", title = _("主体形态"),
                    status = wide and _("宽屏") or _("窄屏"),
                    callback = function()
                        Popup.list{
                            title = _("主体形态"),
                            items = {
                                { text = _("宽屏"), value = "wide" },
                                { text = _("窄屏"), value = "narrow" },
                            },
                            current = wide and "wide" or "narrow",
                            choice_icons = true, centered = true,
                            on_select = function(value)
                                if not value then return end
                                local next_wide = value == "wide"
                                if next_wide == wide then return end
                                Settings.setWide(next_wide)
                                refreshAfterChange(desktop)
                            end,
                        }
                    end,
                })
            end
        end
    end

    if component == "bill" then
        rows[#rows + 1] = function(iw)
            local period = Settings.billPeriod()
            return SettingRow.build(iw, {
                kind = "nav", icon = "date_range", title = _("账单周期"),
                status = Bill.periodLabel(period),
                callback = function()
                    Popup.list{
                        title = _("账单周期"),
                        items = Bill.periodOptions(),
                        current = period, choice_icons = true, centered = true,
                        on_select = function(value)
                            if not value or value == period then return end
                            Settings.setBillPeriod(value)
                            refreshAfterChange(desktop)
                        end,
                    }
                end,
            })
        end
    end

    if component == "message" then
        rows[#rows + 1] = function(iw)
            local text = Settings.customMessage()
            local preview = Text.truncateUtf8(text, 18)
            if preview ~= text then preview = preview .. "…" end
            return SettingRow.build(iw, {
                kind = "nav", icon = "chat", title = _("自定义留言"),
                status = preview,
                callback = function() editMessage(desktop) end,
            })
        end
    end

    return rows
end

return Lockscreen
