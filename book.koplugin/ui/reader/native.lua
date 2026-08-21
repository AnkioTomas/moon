--[[--
将 Book 阅读动作作为 KOReader 顶部原生菜单的独立图标 Tab。

实现与 ui.desktop.panel.native 对齐：只对带 marker 的 Tab 接管
TouchMenu 内容渲染，原生菜单遮罩、Tab、关闭手势和其他页面完全保留。
设置 Tab 仅替换状态栏入口；Aa 字体项注入 ReaderConfig。

@module koplugin.book.ui.reader.native
--]]

require("l10n").apply()

local Device = require("device")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local logger = require("logger")

local Native = {}
local TAB_MARKER = "_book_reader_panel"

local function closeMenu(menu)
    if menu and menu.closeMenu then menu:closeMenu() end
end

local function refreshMenu(menu)
    if menu and menu.updateItems then menu:updateItems(1) end
end

local function refreshReader(ui)
    if ui then UIManager:setDirty(ui.dialog, "ui") end
    require("lockscreen.init").refreshInBackground()
end

local function setDisplay(ui, key, value, menu)
    local settings = require("utils.settings").get()
    settings[key] = value
    require("utils.settings").save(settings)
    refreshReader(ui)
    refreshMenu(menu)
end

local function saveDefault(ui, menu)
    closeMenu(menu)
    if ui and ui.menu and ui.menu.saveDocumentSettingsAsDefault then
        ui.menu:saveDocumentSettingsAsDefault()
    end
    require("utils.settings").save(require("utils.settings").get())
    UIManager:show(require("ui/widget/infomessage"):new{
        text = _("默认配置已保存"), timeout = 2,
    })
    refreshReader(ui)
end

local function settingsItems(ui)
    return {
        {
            id = "book_reader_top_status",
            text = _("顶部状态栏"),
            checked_func = function()
                return require("utils.settings").get().book_reader_show_top_time ~= false
            end,
            callback = function(menu)
                local settings = require("utils.settings").get()
                setDisplay(ui, "book_reader_show_top_time",
                    settings.book_reader_show_top_time == false, menu)
            end,
            keep_menu_open = true,
        },
        {
            id = "book_reader_bottom_progress",
            text = _("底部进度栏"),
            checked_func = function()
                return require("utils.settings").get().book_reader_show_bottom_progress ~= false
            end,
            callback = function(menu)
                local settings = require("utils.settings").get()
                setDisplay(ui, "book_reader_show_bottom_progress",
                    settings.book_reader_show_bottom_progress == false, menu)
            end,
            keep_menu_open = true,
        },
        {
            id = "book_reader_save_default",
            text = _("保存当前配置为默认配置"),
            separator = true,
            callback = function(menu) saveDefault(ui, menu) end,
        },
    }
end

local function findItem(items, id)
    for _, item in ipairs(items or {}) do
        if type(item) == "table" then
            if item.id == id then return item end
            local children = item.sub_item_table or (#item > 0 and item or nil)
            local found = findItem(children, id)
            if found then return found end
        end
    end
end

local function removeItem(items, id)
    if type(items) ~= "table" then return end
    for i = #items, 1, -1 do
        local item = items[i]
        if type(item) == "table" and item.id == id then
            table.remove(items, i)
        elseif type(item) == "table" then
            removeItem(item.sub_item_table or (#item > 0 and item or nil), id)
        end
    end
end

local function injectSettings(menu)
    removeItem(menu.tab_item_table, "status_bar")
    local setting = findItem(menu.tab_item_table, "setting")
    if not setting then return end
    local target = setting.sub_item_table or setting
    for _, item in ipairs(settingsItems(menu.ui)) do
        if not findItem(target, item.id) then target[#target + 1] = item end
    end
end

local function populate(tab)
    for i = #tab, 1, -1 do table.remove(tab, i) end
    for _, action in ipairs(require("ui.reader").actions(tab._book_ui)) do
        local id = action.id
        tab[#tab + 1] = {
            text = action.title,
            enabled_func = function() return action.enabled end,
            keep_menu_open = true,
            callback = function(menu)
                require("ui.reader").executeAction(id, tab._book_ui, {
                    close = function() closeMenu(menu) end,
                    refresh = function() refreshMenu(menu) end,
                })
            end,
        }
    end
end

local Widgets
local NativeAction

local function ensureWidgets()
    if Widgets then return Widgets end
    Widgets = {
        Blitbuffer = require("ffi/blitbuffer"),
        CenterContainer = require("ui/widget/container/centercontainer"),
        FrameContainer = require("ui/widget/container/framecontainer"),
        Geom = require("ui/geometry"),
        GestureRange = require("ui/gesturerange"),
        HorizontalGroup = require("ui/widget/horizontalgroup"),
        HorizontalSpan = require("ui/widget/horizontalspan"),
        InputContainer = require("ui/widget/container/inputcontainer"),
        TextWidget = require("ui/widget/textwidget"),
        VerticalGroup = require("ui/widget/verticalgroup"),
        VerticalSpan = require("ui/widget/verticalspan"),
        UI = require("ui.components.bookui"),
        Icon = require("ui.components.icon"),
    }

    NativeAction = Widgets.InputContainer:extend{}
    function NativeAction:init()
        local W = Widgets
        self.dimen = W.Geom:new{ w = self.width, h = self.height }
        self.ges_events = { Tap = { W.GestureRange:new{ ges = "tap", range = self.dimen } } }
        local fg = self.active and W.Blitbuffer.COLOR_WHITE
            or self.enabled and W.Blitbuffer.COLOR_BLACK or W.UI.muted()
        self[1] = W.FrameContainer:new{
            bordersize = W.UI.line(),
            color = self.active and W.Blitbuffer.COLOR_BLACK or W.UI.rule(),
            background = self.active and W.Blitbuffer.COLOR_BLACK or W.Blitbuffer.COLOR_WHITE,
            padding = W.UI.sz(4),
            width = self.width,
            height = self.height,
            dimen = W.Geom:new{ w = self.width, h = self.height },
            W.CenterContainer:new{
                dimen = W.Geom:new{ w = self.width - W.UI.sz(10), h = self.height - W.UI.sz(10) },
                W.VerticalGroup:new{
                    align = "center",
                    W.Icon.widget{ name = self.icon, size = 26, color = fg, dim = not self.enabled },
                    W.VerticalSpan:new{ width = W.UI.sz(4) },
                    W.TextWidget:new{
                        text = self.title,
                        face = W.UI.face("xx_smallinfofont", 12),
                        fgcolor = fg,
                        max_width = self.width - W.UI.sz(18),
                    },
                },
            },
        }
    end
    function NativeAction:onTap()
        if not self.enabled then return true end
        require("ui.reader").executeAction(self.action_id, self.ui, {
            close = function() closeMenu(self.menu) end,
            refresh = function() refreshMenu(self.menu) end,
        })
        return true
    end
    return Widgets
end

local function buildPanel(menu)
    local W = ensureWidgets()
    local tab = menu.item_table
    local actions = require("ui.reader").actions(tab._book_ui)
    local width, pad = menu.item_width, W.UI.sz(8)
    local content_w = width - pad * 2
    local max_columns = Device.screen:getWidth() > Device.screen:getHeight() and 6 or 4
    local columns = math.max(2, math.min(max_columns, #actions))
    local gap, tile_h = W.UI.sz(8), W.UI.sz(76)
    local tile_w = math.floor((content_w - gap * (columns - 1)) / columns)
    local rows = math.max(1, math.ceil(#actions / columns))
    local group = W.VerticalGroup:new{ align = "left" }
    local row
    for i, action in ipairs(actions) do
        if (i - 1) % columns == 0 then
            if row then
                table.insert(group, row)
                table.insert(group, W.VerticalSpan:new{ width = gap })
            end
            row = W.HorizontalGroup:new{ align = "center" }
        else
            table.insert(row, W.HorizontalSpan:new{ width = gap })
        end
        table.insert(row, NativeAction:new{
            width = tile_w,
            height = tile_h,
            action_id = action.id,
            title = action.title,
            icon = action.icon,
            active = action.active,
            enabled = action.enabled,
            ui = tab._book_ui,
            menu = menu,
        })
    end
    if row then table.insert(group, row) end
    local height = pad * 2 + rows * tile_h + (rows - 1) * gap
    return W.FrameContainer:new{
        bordersize = 0,
        padding = pad,
        background = W.Blitbuffer.COLOR_WHITE,
        width = width,
        height = height,
        dimen = W.Geom:new{ w = width, h = height },
        group,
    }
end

local function updateNativePanel(menu)
    ensureWidgets()
    menu.page, menu.page_num = 1, 1
    menu.item_group:clear()
    menu.layout = {}
    table.insert(menu.item_group, menu.bar)
    table.insert(menu.layout, menu.bar.icon_widgets)
    table.insert(menu.item_group, buildPanel(menu))
    table.insert(menu.item_group, menu.footer_top_margin)
    table.insert(menu.item_group, menu.footer)
    menu.page_info_text:setText("")
    menu.page_info_left_chev:showHide(false)
    menu.page_info_right_chev:showHide(false)
    local old_dimen = menu.dimen:copy()
    menu.dimen.w = menu.width
    menu.dimen.h = menu.item_group:getSize().h + menu.bordersize * 2 + menu.padding
    UIManager:setDirty((menu.is_fresh or menu.dimen.h >= old_dimen.h) and menu.show_parent or "all", function()
        local dimen = old_dimen:combine(menu.dimen)
        local refresh = menu.is_fresh and "flashui" or "ui"
        menu.is_fresh = false
        return refresh, dimen
    end)
end

local function patchTouchMenu()
    local ok, TouchMenu = pcall(require, "ui/widget/touchmenu")
    if not ok or TouchMenu._book_reader_panel_patched then return end
    TouchMenu._book_reader_panel_patched = true
    local original = TouchMenu.updateItems
    TouchMenu.updateItems = function(self, ...)
        if self.item_table and self.item_table[TAB_MARKER] and Device:isTouchDevice() then
            return updateNativePanel(self)
        end
        return original(self, ...)
    end
end

local function newTab(ui)
    local tab = {
        icon = "book",
        remember = false,
        _book_ui = ui,
        [TAB_MARKER] = true,
    }
    tab.callback = function() populate(tab) end
    populate(tab)
    return tab
end

local function injectTab(menu)
    local tabs = menu and menu.tab_item_table
    if type(tabs) ~= "table" then return end
    for _, tab in ipairs(tabs) do
        if tab[TAB_MARKER] then
            tab._book_ui = menu.ui
            return
        end
    end
    table.insert(tabs, 1, newTab(menu.ui))
end

local function installReaderMenu()
    local ok, ReaderMenu = pcall(require, "apps/reader/modules/readermenu")
    if not ok or type(ReaderMenu) ~= "table" or ReaderMenu._book_reader_panel_patched
        or type(ReaderMenu.setUpdateItemTable) ~= "function" then return end
    ReaderMenu._book_reader_panel_patched = true
    local original = ReaderMenu.setUpdateItemTable
    ReaderMenu.setUpdateItemTable = function(self, ...)
        original(self, ...)
        injectSettings(self)
        injectTab(self)
    end
end

local function fontFaces(ui)
    local font = ui and ui.font
    if not font or type(font.onSetFont) ~= "function" then return {}, nil end
    local ok, cre = pcall(function()
        return require("document/credocument"):engineInit()
    end)
    if not ok or not cre or type(cre.getFontFaces) ~= "function" then
        return {}, font.font_face
    end
    return cre.getFontFaces() or {}, font.font_face
end

local function addFontOption(options)
    for group_index, group in ipairs(options) do
        if group.icon == "appbar.textsize" then
            for option_index, option in ipairs(group.options or {}) do
                if option._book_font_option then return end
            end
            group.options[#group.options + 1] = {
                _book_font_option = true,
                name = "book_font_face",
                name_text = _("字体"),
                toggle = { _("选择") },
                values = { 1 },
                args = { 1 },
                default_value = 1,
                event = "BookSetFont",
                more_options = true,
                more_options_param = {
                    value_table = { "" },
                    value_min = 1,
                    value_max = 1,
                    event = "BookSetFont",
                },
            }
            return
        end
    end
end

local function prepareFontOption(config)
    local option
    for _, group in ipairs(config.options or {}) do
        if group.icon == "appbar.textsize" then
            for _, item in ipairs(group.options or {}) do
                if item._book_font_option then option = item break end
            end
        end
    end
    if not option then return end
    local faces, current = fontFaces(config.ui)
    if #faces == 0 then option.show = false return end
    local index = 1
    for i, face in ipairs(faces) do
        if face == current then index = i break end
    end
    config._book_font_faces = faces
    config.configurable.book_font_face = index
    option.show = true
    option.toggle = { faces[index] }
    option.values = { index }
    option.args = { index }
    option.default_value = index
    option.more_options_param.value_table = faces
    option.more_options_param.value_min = 1
    option.more_options_param.value_max = #faces
    option.more_options_param.show_true_value_func = function(value)
        return faces[value] or ""
    end
end

local function installReaderConfig(ui)
    local ok, ReaderConfig = pcall(require, "apps/reader/modules/readerconfig")
    if not ok or type(ReaderConfig) ~= "table" then return end
    addFontOption(require("ui/data/koptoptions"))
    addFontOption(require("ui/data/creoptions"))
    if not ReaderConfig._book_reader_font_patched then
        ReaderConfig._book_reader_font_patched = true
        local original_init = ReaderConfig.init
        ReaderConfig.init = function(self, ...)
            original_init(self, ...)
            prepareFontOption(self)
        end
        local original_show = ReaderConfig.onShowConfigMenu
        ReaderConfig.onShowConfigMenu = function(self, ...)
            prepareFontOption(self)
            return original_show(self, ...)
        end
        function ReaderConfig:onBookSetFont(index)
            local face = self._book_font_faces and self._book_font_faces[tonumber(index)]
            if face and self.ui and self.ui.font then self.ui.font:onSetFont(face) end
            return true
        end
        local original_save = ReaderConfig.onSaveSettings
        if type(original_save) == "function" then
            ReaderConfig.onSaveSettings = function(self, ...)
                self.configurable.book_font_face = nil
                return original_save(self, ...)
            end
        end
    end
    if ui and ui.config then prepareFontOption(ui.config) end
end

--- 安装阅读页独立图标 Tab、设置项和 Aa 字体入口；可安全重复调用。
---@param ui table|nil
function Native.install(ui)
    patchTouchMenu()
    local ok, err = pcall(installReaderMenu)
    if not ok then logger.err("book reader native menu install failed:", err) end
    ok, err = pcall(installReaderConfig, ui)
    if not ok then logger.err("book reader native config install failed:", err) end
    if ui and ui.menu then
        injectSettings(ui.menu)
        injectTab(ui.menu)
    end
end

return Native
