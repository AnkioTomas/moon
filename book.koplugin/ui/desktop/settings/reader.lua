--[[-- 阅读设置：X-Ray、顶底栏、翻页动画、划词弹窗项显隐。
@module koplugin.book.ui.desktop.settings.reader
--]]

local InfoMessage = require("ui/widget/infomessage")
local ButtonDialog = require("ui/widget/buttondialog")
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
    -- 保持 wikipedia id，兼容已保存的划词菜单显示设置。
    { id = "wikipedia", title = _("百度百科"), icon = "language" },
    { id = "dictionary", title = _("词典"), icon = "book" },
    { id = "translate", title = _("翻译"), icon = "translate" },
    { id = "xray", title = _("X-Ray 查询"), icon = "person_search" },
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

---@param reader table
---@return string[]
local function popupOrder(reader)
    local out, seen = {}, {}
    for _, key in ipairs(reader.reader_popup_button_order or {}) do
        if not seen[key] then
            out[#out + 1], seen[key] = key, true
        end
    end
    for _, item in ipairs(POPUP_BUTTONS) do
        if not seen[item.id] then
            out[#out + 1], seen[item.id] = item.id, true
        end
    end
    return out
end

---@param desktop table
---@param item { id: string, title: string, icon: string }
---@return fun(width: number): table
local function popupConfigureRow(desktop, item)
    return function(iw)
        local reader = MoonSettings.get("reader")
        local buttons = reader.reader_popup_buttons or {}
        local order = popupOrder(reader)
        local position
        for i, key in ipairs(order) do
            if key == item.id then position = i break end
        end
        local enabled = buttons[item.id] ~= false
        return SettingRow.build(iw, {
            kind = "nav", icon = item.icon, title = item.title,
            status = enabled and T(_("第 %1 位"), position) or _("关闭"), status_on = enabled,
            callback = function()
                local dialog
                local actions = {
                    {
                        {
                            text = enabled and _("停用") or _("启用"),
                            callback = function()
                                reader.reader_popup_buttons = reader.reader_popup_buttons or {}
                                reader.reader_popup_buttons[item.id] = not enabled
                                MoonSettings.saveSection("reader", reader)
                                UIManager:close(dialog)
                                desktop:rebuild()
                            end,
                        },
                    },
                }
                if enabled then
                    local function move(delta)
                        local next_pos = position + delta
                        order[position], order[next_pos] = order[next_pos], order[position]
                        reader.reader_popup_button_order = order
                        MoonSettings.saveSection("reader", reader)
                        UIManager:close(dialog)
                        desktop:rebuild()
                    end
                    actions[#actions + 1] = {
                        { text = _("上移"), enabled = position > 1, callback = function() move(-1) end },
                        { text = _("下移"), enabled = position < #order, callback = function() move(1) end },
                    }
                end
                actions[#actions + 1] = {{
                    text = _("关闭"), callback = function() UIManager:close(dialog) end,
                }}
                dialog = ButtonDialog:new{
                    title = item.title, title_align = "center", use_info_style = false, buttons = actions,
                }
                UIManager:show(dialog)
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
    local edge_translation_on = reader.edge_translation_enabled ~= false
    local baike_on = reader.baike_enabled ~= false
    local dictionary_on = reader.dictionary_enabled ~= false

    local popup_rows = {}
    for _, item in ipairs(POPUP_BUTTONS) do
        popup_rows[#popup_rows + 1] = popupConfigureRow(desktop, item)
    end
    local translation_rows = {
        function(iw)
            return SettingRow.build(iw, {
                kind = "toggle", icon = "translate", title = _("Edge 翻译"),
                status = edge_translation_on and _("开") or _("关"), status_on = edge_translation_on,
                callback = function()
                    reader.edge_translation_enabled = not edge_translation_on
                    MoonSettings.saveSection("reader", reader)
                    desktop:rebuild()
                end,
            })
        end,
    }
    if edge_translation_on then
        translation_rows[#translation_rows + 1] = function(iw)
            local Languages = require("translate.languages")
            local Translator = require("ui/translator")
            return SettingRow.build(iw, {
                kind = "nav",
                icon = "translate",
                title = _("常用翻译语言"),
                status = T(_("%1 种"), #Languages.favoriteCodes()),
                callback = function()
                    Languages.openSettingsPicker(Translator, desktop)
                end,
            })
        end
    end
    local dictionary_rows = {
        function(iw)
            return SettingRow.build(iw, {
                kind = "toggle", icon = "book", title = _("Book 词典"),
                status = dictionary_on and _("开") or _("关"), status_on = dictionary_on,
                callback = function()
                    reader.dictionary_enabled = not dictionary_on
                    MoonSettings.saveSection("reader", reader)
                    desktop:rebuild()
                end,
            })
        end,
    }
    if dictionary_on then
        dictionary_rows[#dictionary_rows + 1] = function(iw)
            return SettingRow.build(iw, {
                kind = "nav", icon = "cloud_download", title = _("下载词典"),
                callback = function()
                    require("dictionary.ui").download(readerUi())
                end,
            })
        end
        dictionary_rows[#dictionary_rows + 1] = function(iw)
            return SettingRow.build(iw, {
                kind = "nav", icon = "settings", title = _("管理词典"),
                callback = function()
                    require("dictionary.ui").manage(readerUi())
                end,
            })
        end
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
        {
            title = _("词典"),
            rows = dictionary_rows,
        },
        {
            title = _("翻译"),
            rows = translation_rows,
        },
        {
            title = _("百科"),
            rows = {
                function(iw)
                    return SettingRow.build(iw, {
                        kind = "toggle", icon = "language", title = _("百度百科"),
                        status = baike_on and _("开") or _("关"), status_on = baike_on,
                        callback = function()
                            reader.baike_enabled = not baike_on
                            MoonSettings.saveSection("reader", reader)
                            desktop:rebuild()
                        end,
                    })
                end,
            },
        },
    }
end

return ReaderSettings
