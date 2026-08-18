--[[--
将 Book 快捷动作作为 KOReader 原生菜单的一个 Tab。

仅在 FileManagerMenu / ReaderMenu 构建 Tab 表时插入一项。触屏设备只对
这个 Tab 替换 TouchMenu 的内容渲染；原生菜单的遮罩、Tab、关闭和其他
菜单页面均保持 KOReader 实现。动作数据、执行和设备能力判断全部由
ui.desktop.panel 提供，两个入口不会产生两套配置。

@module koplugin.book.ui.desktop.panel.native
--]]

require("l10n").apply()

local Device = require("device")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local logger = require("logger")

local NativePanel = {}
local TAB_MARKER = "_book_quick_panel"

local function refreshMenu(menu)
    if menu and menu.updateItems then menu:updateItems(1) end
end

local function closeMenu(menu)
    if menu and menu.closeMenu then menu:closeMenu() end
end

local function percent(value, min, max)
    if max <= min then return 0 end
    return math.max(0, math.min(100, math.floor((value - min) * 100 / (max - min) + 0.5)))
end

local function populate(tab)
    local Panel = require("ui.desktop.panel")
    for i = #tab, 1, -1 do table.remove(tab, i) end
    for _, action in ipairs(Panel.menuActions()) do
        local id, title = action.id, action.title
        tab[#tab + 1] = {
            text = title,
            keep_menu_open = true,
            callback = function(menu)
                Panel.executeAction(id, {
                    close = function() closeMenu(menu) end,
                    refresh = function() refreshMenu(menu) end,
                })
            end,
        }
    end
end

local Widgets
local NativeAction
local NativeSlider

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
        ProgressWidget = require("ui/widget/progresswidget"),
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
        local fg = self.active and W.Blitbuffer.COLOR_WHITE or W.Blitbuffer.COLOR_BLACK
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
                    W.Icon.widget{ name = self.icon, size = 24, color = fg },
                    W.VerticalSpan:new{ width = W.UI.sz(3) },
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
        local Panel = require("ui.desktop.panel")
        Panel.executeAction(self.action_id, {
            close = function() closeMenu(self.menu) end,
            refresh = function() refreshMenu(self.menu) end,
        })
        return true
    end

    NativeSlider = Widgets.InputContainer:extend{}
    function NativeSlider:init()
        local W = Widgets
        self.dimen = W.Geom:new{ w = self.width, h = self.height }
        self.ges_events = {
            Tap = { W.GestureRange:new{ ges = "tap", range = self.dimen } },
            Pan = { W.GestureRange:new{ ges = "pan", range = self.dimen } },
            PanRelease = { W.GestureRange:new{ ges = "pan_release", range = self.dimen } },
        }
        local label_w, value_w = W.UI.sz(72), W.UI.sz(42)
        local bar_w = self.width - label_w - value_w - W.UI.sz(16)
        self.bar_x, self.bar_w = label_w + W.UI.sz(8), bar_w
        self.progress = W.ProgressWidget:new{
            width = bar_w, height = W.UI.sz(22), percentage = self.value / 100,
            radius = 0, bordersize = W.UI.line(), bgcolor = W.UI.track(), fillcolor = W.Blitbuffer.COLOR_BLACK,
        }
        self[1] = W.HorizontalGroup:new{
            align = "center",
            W.CenterContainer:new{
                dimen = W.Geom:new{ w = label_w, h = self.height },
                W.TextWidget:new{ text = self.title, face = W.UI.face("cfont", 13), max_width = label_w },
            },
            W.HorizontalSpan:new{ width = W.UI.sz(8) },
            self.progress,
            W.HorizontalSpan:new{ width = W.UI.sz(8) },
            W.CenterContainer:new{
                dimen = W.Geom:new{ w = value_w, h = self.height },
                W.TextWidget:new{ text = string.format("%d%%", self.value), face = W.UI.face("xx_smallinfofont", 12), max_width = value_w },
            },
        }
    end
    function NativeSlider:setFromPosition(pos, finish)
        if not pos or not self.dimen then return false end
        local fraction = math.max(0, math.min(1, (pos.x - self.dimen.x - self.bar_x) / self.bar_w))
        local Panel = require("ui.desktop.panel")
        if not Panel.setLevel(self.kind, fraction) then return false end
        self.progress.percentage = fraction
        UIManager:setDirty(self, "ui")
        if finish then refreshMenu(self.menu) end
        return true
    end
    function NativeSlider:onTap(_, ges) return self:setFromPosition(ges and ges.pos, true) end
    function NativeSlider:onPan(_, ges) return self:setFromPosition(ges and ges.pos, false) end
    function NativeSlider:onPanRelease(_, ges) return self:setFromPosition(ges and ges.pos, true) end
    return Widgets
end

local function lightValue(kind)
    local powerd = Device:getPowerDevice()
    if kind == "brightness" then
        local min, max = tonumber(powerd.fl_min) or 0, tonumber(powerd.fl_max) or 100
        return percent(tonumber(powerd:frontlightIntensity()) or min, min, max)
    end
    local min = tonumber(powerd.fl_warmth_min) or 0
    local max = tonumber(powerd.fl_warmth_max) or 100
    return percent(powerd:toNativeWarmth(powerd:frontlightWarmth()), min, max)
end

local function buildPanel(menu)
    local W = ensureWidgets()
    local Panel = require("ui.desktop.panel")
    local actions = Panel.menuActions()
    local icons = {}
    for _, option in ipairs(Panel.options()) do
        icons[option.id] = option.icon
    end
    local width, pad = menu.item_width, W.UI.sz(8)
    local content_w = width - pad * 2
    local screen = Device.screen
    local max_columns = screen:getWidth() > screen:getHeight() and 6 or 4
    local columns = math.max(2, math.min(max_columns, #actions))
    local gap, tile_h = W.UI.sz(8), W.UI.sz(68)
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
        local icon = icons[action.id] or action.id
        if action.id == "night" then icon = "dark_mode"
        elseif action.id == "wifi" then icon = "wifi" end
        table.insert(row, NativeAction:new{
            width = tile_w, height = tile_h, action_id = action.id, title = action.title,
            icon = icon, active = action.active, menu = menu,
        })
    end
    if row then table.insert(group, row) end

    local has_light, has_warmth = Device:hasFrontlight(), Device:hasNaturalLight()
    local slider_h = W.UI.sz(42)
    if has_light or has_warmth then table.insert(group, W.VerticalSpan:new{ width = W.UI.sz(12) }) end
    if has_light then
        table.insert(group, NativeSlider:new{
            width = content_w, height = slider_h, title = _("亮度"), kind = "brightness",
            value = lightValue("brightness"), menu = menu,
        })
    end
    if has_warmth then
        table.insert(group, NativeSlider:new{
            width = content_w, height = slider_h, title = _("冷暖色调"), kind = "warmth",
            value = lightValue("warmth"), menu = menu,
        })
    end
    local height = pad * 2 + rows * tile_h + (rows - 1) * gap
        + ((has_light or has_warmth) and W.UI.sz(12) or 0)
        + (has_light and slider_h or 0) + (has_warmth and slider_h or 0)
    return W.FrameContainer:new{
        bordersize = 0, padding = pad, background = W.Blitbuffer.COLOR_WHITE,
        width = width, height = height, dimen = W.Geom:new{ w = width, h = height }, group,
    }
end

local function updateNativePanel(menu)
    local W = ensureWidgets()
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
    if not ok or TouchMenu._book_quick_panel_patched then return end
    TouchMenu._book_quick_panel_patched = true
    local original = TouchMenu.updateItems
    TouchMenu.updateItems = function(self, ...)
        if self.item_table and self.item_table[TAB_MARKER] and Device:isTouchDevice() then
            return updateNativePanel(self)
        end
        return original(self, ...)
    end
end

local function newTab()
    local tab = {
        icon = "appbar.contrast",
        remember = false,
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
        if tab[TAB_MARKER] then return end
    end
    table.insert(tabs, 1, newTab())
end

local function installMenu(module_name)
    local ok, Menu = pcall(require, module_name)
    if not ok or type(Menu) ~= "table" or Menu._book_quick_panel_patched then return end
    if type(Menu.setUpdateItemTable) ~= "function" then return end
    Menu._book_quick_panel_patched = true
    local original = Menu.setUpdateItemTable
    Menu.setUpdateItemTable = function(self, ...)
        original(self, ...)
        injectTab(self)
    end
end

local function activeMenu()
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    local reader = ok and ReaderUI.instance or nil
    if reader and not reader.tearing_down and reader.menu then return reader.menu end

    ok, FileManager = pcall(require, "apps/filemanager/filemanager")
    local file_manager = ok and FileManager.instance or nil
    if file_manager and not file_manager.tearing_down and file_manager.menu then
        return file_manager.menu
    end
end

--- 打开 KOReader 原生菜单，并直接选中 Book 快捷 Tab。
---@return boolean
function NativePanel.show()
    local menu = activeMenu()
    if not menu then return false end
    if not menu.tab_item_table and menu.setUpdateItemTable then menu:setUpdateItemTable() end
    injectTab(menu)
    local tab_index
    for i, tab in ipairs(menu.tab_item_table or {}) do
        if tab[TAB_MARKER] then tab_index = i break end
    end
    if not tab_index then return false end

    local opened = menu.menu_container and menu.menu_container[1]
    if opened and opened.switchMenuTab then
        opened:switchMenuTab(tab_index)
    elseif menu.onShowMenu then
        menu:onShowMenu(tab_index)
    else
        return false
    end
    return true
end

--- 安装 FileManager 与 Reader 的原生菜单 Tab；可安全重复调用。
---@param host_ui table|nil 当前插件宿主（FileManager 或 ReaderUI）
function NativePanel.install(host_ui)
    patchTouchMenu()
    local ok, err = pcall(installMenu, "apps/filemanager/filemanagermenu")
    if not ok then logger.err("book native quick panel install failed for file manager:", err) end
    ok, err = pcall(installMenu, "apps/reader/modules/readermenu")
    if not ok then logger.err("book native quick panel install failed for reader:", err) end
    if host_ui and host_ui.menu then injectTab(host_ui.menu) end
end

return NativePanel
