--[[-- 阅读设置：X-Ray、顶底栏、翻页动画、划词弹窗项显隐。
@module koplugin.book.ui.desktop.settings.reader
--]]

local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local MoonSettings = require("utils.settings")
local SettingRow = require("ui.components.settingrow")
local Bars = require("ui.reader.bars")
local PageTurnAnimation = require("patch.page_turn_animation")
local _ = require("gettext")
local T = require("ffi/util").template

local ReaderSettings = {}

---@type { id: string, title: string, icon: string }[]
local POPUP_BUTTONS = {
    { id = "select", title = _("选择"), icon = "highlight" },
    { id = "highlight", title = _("高亮"), icon = "format_ink_highlighter" },
    { id = "copy", title = _("复制"), icon = "content_copy" },
    { id = "add_note", title = _("添加笔记"), icon = "note_add" },
    { id = "wikipedia", title = _("维基百科"), icon = "language" },
    { id = "dictionary", title = _("词典"), icon = "book" },
    { id = "translate", title = _("翻译"), icon = "translate" },
    { id = "view_html", title = _("查看HTML"), icon = "code" },
    { id = "qrcode", title = _("生成二维码"), icon = "qr_code" },
    { id = "search", title = _("搜索"), icon = "search" },
}

---@return table|nil
local function readerUi()
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    return ok and ReaderUI.instance or nil
end

---@return nil
local function refreshReaderUi()
    local ui = readerUi()
    if ui and ui.dialog then
        UIManager:setDirty(ui.dialog, "ui")
    end
end

---@param desktop table
---@param key string
---@param title string
---@param icon string
---@return fun(width: number): table
local function popupToggleRow(desktop, key, title, icon)
    return function(iw)
        local reader = MoonSettings.get("reader")
        local buttons = reader.reader_popup_buttons or {}
        local on = buttons[key] ~= false
        return SettingRow.build(iw, {
            kind = "toggle", icon = icon, title = title,
            status = on and _("开") or _("关"), status_on = on,
            callback = function()
                reader.reader_popup_buttons = reader.reader_popup_buttons or {}
                reader.reader_popup_buttons[key] = not on
                MoonSettings.saveSection("reader", reader)
                desktop:rebuild()
            end,
        })
    end
end

---@param desktop table
---@return BookQuickPanelSettingSection[]
function ReaderSettings.sections(desktop)
    local reader = MoonSettings.get("reader")
    local xray_on = reader.book_xray_enabled ~= false
    local marks_on = reader.book_xray_show_marks ~= false
    local top_on = Bars.topBarPreference()
    local bottom_on = Bars.bottomBarPreference()
    local animation_on = PageTurnAnimation.isEnabled()

    local popup_rows = {}
    for _, item in ipairs(POPUP_BUTTONS) do
        popup_rows[#popup_rows + 1] = popupToggleRow(desktop, item.id, item.title, item.icon)
    end

    return {
        {
            title = _("X-Ray"),
            rows = {
                function(iw)
                    return SettingRow.build(iw, {
                        kind = "toggle", icon = "person_search", title = _("X-Ray 功能"),
                        status = xray_on and _("开") or _("关"), status_on = xray_on,
                        callback = function()
                            reader.book_xray_enabled = not xray_on
                            MoonSettings.saveSection("reader", reader)
                            require("xray.marks").invalidate()
                            desktop:rebuild()
                        end,
                    })
                end,
                function(iw)
                    return SettingRow.build(iw, {
                        kind = "toggle", icon = "format_underlined", title = _("X-Ray实体画线"),
                        status = (xray_on and marks_on) and _("开") or _("关"),
                        status_on = xray_on and marks_on,
                        callback = function()
                            if not xray_on then return end
                            reader.book_xray_show_marks = not marks_on
                            MoonSettings.saveSection("reader", reader)
                            require("xray.marks").invalidate()
                            refreshReaderUi()
                            desktop:rebuild()
                        end,
                    })
                end,
            },
        },
        {
            title = _("阅读页"),
            rows = {
                function(iw)
                    return SettingRow.build(iw, {
                        kind = "toggle", icon = "vertical_align_top", title = _("顶部状态栏"),
                        status = top_on and _("开") or _("关"), status_on = top_on,
                        callback = function()
                            Bars.setTopBarPreference(not top_on, readerUi())
                            refreshReaderUi()
                            desktop:rebuild()
                        end,
                    })
                end,
                function(iw)
                    return SettingRow.build(iw, {
                        kind = "toggle", icon = "horizontal_rule", title = _("底部进度栏"),
                        status = bottom_on and _("开") or _("关"), status_on = bottom_on,
                        callback = function()
                            Bars.setBottomBarPreference(not bottom_on, readerUi())
                            refreshReaderUi()
                            desktop:rebuild()
                        end,
                    })
                end,
                function(iw)
                    return SettingRow.build(iw, {
                        kind = "toggle", icon = "animation", title = _("翻页动画"),
                        status = animation_on and _("开") or _("关"), status_on = animation_on,
                        callback = function()
                            local res = PageTurnAnimation.setEnabled(not animation_on)
                            if not res.ok then
                                UIManager:show(InfoMessage:new{
                                    text = T(_("翻页动画补丁操作失败：%1"), tostring(res.err or "")),
                                    timeout = 3,
                                })
                                return
                            end
                            desktop:rebuild()
                            PageTurnAnimation.promptRestart()
                        end,
                    })
                end,
            },
        },
        {
            title = _("阅读弹窗"),
            rows = popup_rows,
        },
    }
end

return ReaderSettings
