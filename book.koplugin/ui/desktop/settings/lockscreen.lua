--[[-- 锁屏设置项。
@module koplugin.book.ui.desktop.settings.lockscreen
--]]

local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local Popup = require("ui.components.popup")
local SettingRow = require("ui.components.settingrow")
local LockScreen = require("lockscreen.init")
local _ = require("gettext")
local T = require("ffi/util").template

local Lockscreen = {}

local function pick(desktop, current)
    Popup.list{
        title = _("锁屏显示"), items = LockScreen.options(), current = current,
        choice_icons = true, centered = true,
        on_select = function(mode)
            if not mode or mode == current then return end
            LockScreen.setMode(mode)
            desktop:rebuild()
            if mode == "ko" then return end
            local function refresh()
                UIManager:show(InfoMessage:new{ text = _("正在下载锁屏图…"), timeout = 2 })
                LockScreen.refresh(function(ok, err)
                    UIManager:show(InfoMessage:new{
                        text = ok and T(_("已设为%1"), LockScreen.label(mode))
                            or T(_("下载失败: %1"), tostring(err or "")), timeout = 2,
                    })
                end)
            end
            if LockScreen.canRefreshOffline(mode) then refresh()
            else NetworkMgr:runWhenOnline(refresh) end
        end,
    }
end

---@param desktop table
---@return table
function Lockscreen.rows(desktop)
    local mode = LockScreen.mode()
    local rows = {
        function(iw)
            return SettingRow.build(iw, {
                kind = "nav", icon = "wallpaper", title = _("锁屏显示"),
                status = LockScreen.label(mode), status_on = mode ~= "ko",
                callback = function() pick(desktop, mode) end,
            })
        end,
    }
    if mode ~= "ko" and mode ~= "myrl" and mode ~= "bookshelf" then
        rows[#rows + 1] = function(iw)
            local labels = { custom = _("自定义"), bing = _("必应壁纸"), none = _("无背景") }
            local background = LockScreen.backgroundMode()
            return SettingRow.build(iw, {
                kind = "nav", icon = "image", title = _("背景壁纸"),
                status = labels[background], subtitle = background == "custom" and LockScreen.backgroundHint() or nil,
                callback = function()
                    Popup.list{
                        title = _("背景壁纸"),
                        items = {
                            { text = labels.custom, value = "custom" },
                            { text = labels.bing .. " · " .. _("每日更新"), value = "bing" },
                            { text = labels.none, value = "none" },
                        },
                        current = background, choice_icons = true, centered = true,
                        on_select = function(value)
                            LockScreen.setBackgroundMode(value)
                            desktop:rebuild()
                            LockScreen.refreshInBackground()
                        end,
                    }
                end,
            })
        end
    end
    if mode == "quote" then
        rows[#rows + 1] = function(iw)
            local labels = { highlight = _("书籍高亮"), hitokoto = _("一言"), none = _("不显示") }
            local quote_mode = LockScreen.quoteMode()
            return SettingRow.build(iw, {
                kind = "nav", icon = "format_quote", title = _("语句来源"), status = labels[quote_mode],
                callback = function()
                    Popup.list{
                        title = _("语句来源"),
                        items = {
                            { text = labels.highlight, value = "highlight" },
                            { text = labels.hitokoto, value = "hitokoto" },
                            { text = labels.none, value = "none" },
                        },
                        current = quote_mode, choice_icons = true, centered = true,
                        on_select = function(value)
                            LockScreen.setQuoteMode(value)
                            desktop:rebuild()
                            LockScreen.refreshInBackground()
                        end,
                    }
                end,
            })
        end
        rows[#rows + 1] = function(iw)
            local positions = {
                ["top-left"] = _("左上"), ["top-center"] = _("上中"), ["top-right"] = _("右上"),
                ["center-left"] = _("左中"), ["center-center"] = _("居中"), ["center-right"] = _("右中"),
                ["bottom-left"] = _("左下"), ["bottom-center"] = _("下中"), ["bottom-right"] = _("右下"),
            }
            local position = LockScreen.quotePosition()
            return SettingRow.build(iw, {
                kind = "nav", icon = "open_in_full", title = _("显示位置"), status = positions[position],
                callback = function()
                    local items = {}
                    for _idx, value in ipairs({ "top-left", "top-center", "top-right", "center-left", "center-center", "center-right", "bottom-left", "bottom-center", "bottom-right" }) do
                        items[#items + 1] = { text = positions[value], value = value }
                    end
                    Popup.list{
                        title = _("显示位置"), items = items, current = position,
                        choice_icons = true, centered = true,
                        on_select = function(value)
                            LockScreen.setQuotePosition(value)
                            desktop:rebuild()
                            LockScreen.refreshInBackground()
                        end,
                    }
                end,
            })
        end
        rows[#rows + 1] = function(iw)
            local wide = LockScreen.quoteWide()
            return SettingRow.build(iw, {
                kind = "toggle", icon = "aspect_ratio", title = _("宽屏显示"),
                status = wide and _("开") or _("关"), status_on = wide,
                callback = function()
                    LockScreen.setQuoteWide(not wide)
                    desktop:rebuild()
                    LockScreen.refreshInBackground()
                end,
            })
        end
    end
    if mode == "bill" then
        rows[#rows + 1] = function(iw)
            local labels = { today = _("今日"), ["7d"] = _("最近 7 天"), ["30d"] = _("最近 30 天"), month = _("本月") }
            local period = LockScreen.billPeriod()
            return SettingRow.build(iw, {
                kind = "nav", icon = "date_range", title = _("账单周期"), status = labels[period],
                callback = function()
                    Popup.list{
                        title = _("账单周期"),
                        items = {
                            { text = labels.today, value = "today" }, { text = labels["7d"], value = "7d" },
                            { text = labels["30d"], value = "30d" }, { text = labels.month, value = "month" },
                        },
                        current = period, choice_icons = true, centered = true,
                        on_select = function(value)
                            LockScreen.setBillPeriod(value)
                            desktop:rebuild()
                            LockScreen.refreshInBackground()
                        end,
                    }
                end,
            })
        end
    end
    return rows
end

return Lockscreen
