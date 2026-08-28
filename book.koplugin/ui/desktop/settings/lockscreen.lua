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
local Components = require("lockscreen.components.base")
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
        end)
    end
    if LockScreen.canRefreshOffline() then
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
        input = LockScreen.customMessage(),
        buttons = {{
            { text = _("取消"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("保存"), is_enter_default = true, callback = function()
                local text = dialog:getInputText()
                UIManager:close(dialog)
                LockScreen.setCustomMessage(text)
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
    local enabled = LockScreen.isCompose()
    local rows = {
        function(iw)
            return SettingRow.build(iw, {
                kind = "toggle", icon = "wallpaper", title = _("替代系统锁屏"),
                status = enabled and _("开") or _("关"), status_on = enabled,
                callback = function()
                    LockScreen.setMode(enabled and "ko" or "compose")
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

    local component = LockScreen.component()
    local component_config = Components.find(component)
    if not component_config or component_config.uses_background ~= false then
        rows[#rows + 1] = function(iw)
            local labels = {
                custom = _("自定义"),
                bing = _("必应壁纸"),
                cover = _("当前阅读书籍封面"),
                folder = _("文件夹壁纸"),
                none = _("无"),
            }
            local background = LockScreen.backgroundMode()
            local subtitle
            if background == "custom" then
                subtitle = LockScreen.backgroundHint()
            elseif background == "folder" then
                subtitle = LockScreen.folderHint()
            end
            return SettingRow.build(iw, {
                kind = "nav", icon = "image", title = _("背景"),
                status = labels[background] or labels.bing,
                subtitle = subtitle,
                callback = function()
                    Popup.list{
                        title = _("背景"),
                        items = LockScreen.backgroundOptions(),
                        current = background, choice_icons = true, centered = true,
                        on_select = function(value)
                            if not value or value == background then return end
                            LockScreen.setBackgroundMode(value)
                            refreshAfterChange(desktop)
                        end,
                    }
                end,
            })
        end
    end

    rows[#rows + 1] = function(iw)
        local component = LockScreen.component()
        local label = _("无")
        for _, item in ipairs(LockScreen.componentOptions()) do
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
                    items = LockScreen.componentOptions(),
                    current = component, choice_icons = true, centered = true,
                    on_select = function(value)
                        if not value or value == component then return end
                        LockScreen.setComponent(value)
                        refreshAfterChange(desktop)
                    end,
                }
            end,
        })
    end

    if component_config and component_config.supports_position ~= false then
        rows[#rows + 1] = function(iw)
            local positions = {
                ["top-left"] = _("左上"), ["top-center"] = _("上中"), ["top-right"] = _("右上"),
                ["center-left"] = _("左中"), ["center-center"] = _("居中"), ["center-right"] = _("右中"),
                ["bottom-left"] = _("左下"), ["bottom-center"] = _("下中"), ["bottom-right"] = _("右下"),
            }
            local position = LockScreen.position()
            return SettingRow.build(iw, {
                kind = "nav", icon = "open_in_full", title = _("主体位置"),
                status = positions[position] or positions["center-center"],
                callback = function()
                    local items = {}
                    for _, value in ipairs({
                        "top-left", "top-center", "top-right",
                        "center-left", "center-center", "center-right",
                        "bottom-left", "bottom-center", "bottom-right",
                    }) do
                        items[#items + 1] = { text = positions[value], value = value }
                    end
                    Popup.list{
                        title = _("主体位置"), items = items, current = position,
                        choice_icons = true, centered = true,
                        on_select = function(value)
                            if not value or value == position then return end
                            LockScreen.setPosition(value)
                            refreshAfterChange(desktop)
                        end,
                    }
                end,
            })
        end

        if LockScreen.supportsNarrow() then
            rows[#rows + 1] = function(iw)
                local wide = LockScreen.wide()
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
                                LockScreen.setWide(next_wide)
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
            local labels = {
                today = _("今日"), ["7d"] = _("最近 7 天"),
                ["30d"] = _("最近 30 天"), month = _("本月"),
            }
            local period = LockScreen.billPeriod()
            return SettingRow.build(iw, {
                kind = "nav", icon = "date_range", title = _("账单周期"),
                status = labels[period] or labels["7d"],
                callback = function()
                    Popup.list{
                        title = _("账单周期"),
                        items = {
                            { text = labels.today, value = "today" },
                            { text = labels["7d"], value = "7d" },
                            { text = labels["30d"], value = "30d" },
                            { text = labels.month, value = "month" },
                        },
                        current = period, choice_icons = true, centered = true,
                        on_select = function(value)
                            if not value or value == period then return end
                            LockScreen.setBillPeriod(value)
                            refreshAfterChange(desktop)
                        end,
                    }
                end,
            })
        end
    end

    if component == "message" then
        rows[#rows + 1] = function(iw)
            local text = LockScreen.customMessage()
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
