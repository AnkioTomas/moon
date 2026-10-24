--[[-- 阅读设置：阅读行为、划词选区、划词菜单项。
@module koplugin.book.desktop.pages.setting.reader
--]]

local Sheet = require("ui.themes.widgets.sheet")
local Position = require("desktop.pages.setting.position")
local MoonSettings = require("utils.settings")
local Row = require("ui.themes.widgets.row")
local _ = require("gettext")
local T = require("ffi/util").template

---@class BookSettingsReader
local ReaderSettings = {}

--- 内置按钮的设置页顺序、标题与图标；划词弹窗扫描到的其余按钮（`reader_popup_seen`）排在后面。
--- 实际弹窗顺序以 HighlightMenu.order() 为准。
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
    { id = "ai_explain", title = _("AI 解释"), icon = "auto_awesome" },
    { id = "view_html", title = _("查看HTML"), icon = "code" },
    { id = "qrcode", title = _("生成二维码"), icon = "qr_code" },
    { id = "search", title = _("搜索"), icon = "search" },
}

--- 按钮来源的展示文字；还没在划词弹窗里出现过的按钮来源未知，返回 nil。
---@param origin string|nil HighlightMenu.originOf 的结果
---@return string|nil
local function originLabel(origin)
    if not origin then return nil end
    if origin == "book" then return _("来自：月读") end
    if origin == "koreader" then return _("来自：KOReader 自带") end
    local plugin = origin:match("^plugin:(.+)$")
    if plugin then return T(_("来自：插件 %1"), plugin) end
    local patch = origin:match("^patch:(.+)$")
    if patch then return T(_("来自：用户补丁 %1"), patch) end
    return _("来自：未知")
end

---@return table|nil
local function readerUi()
    return require("apps/reader/readerui").instance
end

--- 布尔开关行：翻转后落盘并重建桌面。
---@param desktop table
---@param section string 配置分区
---@param data table 该分区的配置表
---@param key string 设置键
---@param on boolean 当前状态
---@param row table 图标、标题等其余 SettingRow 字段
---@return fun(iw: number): table
local function toggleRow(desktop, section, data, key, on, row)
    return function(iw)
        row.toggle = on
        row.callback = function()
            data[key] = not on
            MoonSettings.save(section, data)
            desktop:updateView()
        end
        row.width = iw
        return Row.widget(row)
    end
end

---@param desktop table
---@param item { id: string, title: string, icon: string, subtitle: string|nil }
---@return fun(width: number): table
local function popupConfigureRow(desktop, item)
    return function(iw)
        local reader = MoonSettings.get("reader")
        local buttons = reader.reader_popup_buttons or {}
        local order = require("reader.highlight_menu").order()
        local position
        for i, key in ipairs(order) do
            if key == item.id then position = i break end
        end
        local enabled = buttons[item.id] ~= false
        return Row.widget({
            width = iw,
            kind = "nav", icon = item.icon, title = item.title, subtitle = item.subtitle,
            status = enabled and T(_("第 %1 位"), position) or _("关闭"), status_on = enabled,
            callback = function()
                local actions = {{
                    text = enabled and _("停用") or _("启用"),
                    callback = function()
                        reader.reader_popup_buttons = reader.reader_popup_buttons or {}
                        reader.reader_popup_buttons[item.id] = not enabled
                        MoonSettings.save("reader", reader)
                        desktop:updateView()
                    end,
                }}
                if enabled then
                    local function move(delta)
                        local target = math.max(1, math.min(#order, position + delta))
                        if target == position then return end
                        table.insert(order, target, table.remove(order, position))
                        reader.reader_popup_button_order = order
                        MoonSettings.save("reader", reader)
                        desktop:updateView()
                    end
                    actions[#actions + 1] = { text = _("上移"), enabled = position > 1, callback = function() move(-1) end }
                    actions[#actions + 1] = { text = _("下移"), enabled = position < #order, callback = function() move(1) end }
                    actions[#actions + 1] = Position.item(position, #order, move)
                end
                actions[#actions + 1] = { text = _("关闭") }
                Sheet:new{ title = item.title, items = actions }:show()
            end,
        })
    end
end

--- 构建划词菜单操作列表：内置按钮在前，划词弹窗扫描到的其余按钮按弹窗顺序接在后面。
---@param desktop table
---@return function[]
function ReaderSettings:popupRows(desktop)
    local seen = MoonSettings.get("reader").reader_popup_seen
    local items, listed = {}, {}
    for _idx, item in ipairs(POPUP_BUTTONS) do
        items[#items + 1] = { id = item.id, title = item.title, icon = item.icon }
        listed[item.id] = true
    end
    for _idx, key in ipairs(require("reader.highlight_menu").order()) do
        if not listed[key] then
            items[#items + 1] = { id = key, title = seen[key] and seen[key].title or key, icon = "extension" }
        end
    end
    local rows = {}
    for _idx, item in ipairs(items) do
        item.subtitle = originLabel(seen[item.id] and seen[item.id].origin)
        rows[#rows + 1] = popupConfigureRow(desktop, item)
    end
    return rows
end

---@param desktop table
---@return BookQuickPanelSettingSection[]
function ReaderSettings:sections(desktop)
    local reader = MoonSettings.get("reader")
    local auto_mark_read = reader.auto_mark_read_at_99 == true
    local rows = {
        function(iw)
            local footnote_on = G_reader_settings:isTrue("footnote_link_in_popup")
            return Row.widget({
                width = iw,
                icon = "article", title = _("脚注弹窗"),
                subtitle = _("脚注链接在弹窗中显示，而不是跳转"),
                toggle = footnote_on,
                callback = function()
                    G_reader_settings:saveSetting("footnote_link_in_popup", not footnote_on)
                    desktop:updateView()
                end,
            })
        end,
    }
    rows[#rows + 1] = toggleRow(desktop, "reader", reader, "auto_mark_read_at_99", auto_mark_read, {
        icon = "done_all", title = _("读到 99% 自动标记已读"),
    })
    rows[#rows + 1] = toggleRow(desktop, "reader", reader, "chapter_switch_notice", reader.chapter_switch_notice ~= false, {
        icon = "article", title = _("显示换章提示"),
        subtitle = _("章节类书源切换章节时提示"),
    })
    rows[#rows + 1] = toggleRow(desktop, "reader", reader, "margin_popup", reader.margin_popup == true, {
        icon = "crop", title = _("边距调整弹出提示"),
        subtitle = _("关闭时直接重排，面板不收起；下次打开书生效"),
    })
    return { { title = _("行为"), rows = rows } }
end

--- 查词页「选区」分节。
---@param desktop table
---@return BookQuickPanelSettingSection[]
function ReaderSettings:lookupSections(desktop)
    local reader = MoonSettings.get("reader")
    local handles_on = reader.selection_handles_enabled ~= false
    return {
        {
            title = _("选区"),
            rows = {
                function(iw)
                    return Row.widget({
                        width = iw,
                        icon = "swipe", title = _("划词手柄"),
                        subtitle = _("选区两端可拖指示器"),
                        toggle = handles_on,
                        callback = function()
                            reader.selection_handles_enabled = not handles_on
                            MoonSettings.save("reader", reader)
                            if handles_on then
                                local ui = readerUi()
                                if ui and ui.highlight then
                                    require("reader.selection").detach(ui.highlight)
                                end
                            end
                            desktop:updateView()
                        end,
                    })
                end,
            },
        },
    }
end

return ReaderSettings
