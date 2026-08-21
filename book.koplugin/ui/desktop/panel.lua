--[[--
桌面顶部快捷控制面板。

从桌面顶栏向下滑打开；同一动作集也会出现在 KOReader 原生菜单 Tab。
夜间模式和 Wi-Fi 固定显示，其余系统动作由用户配置；下拉面板底部按设备能力
显示前光亮度和自然光暖度滑杆。

@module koplugin.book.ui.desktop.panel
--]]

require("l10n").apply()

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Event = require("ui/event")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local NetworkMgr = require("ui/network/manager")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")
local _ = require("gettext")
local Screen = Device.screen

local Icon = require("ui.components.icon")
local UI = require("ui.components.bookui")
local Surface = require("ui.components.surface")
local MoonSettings = require("utils.settings")

local Panel = InputContainer:extend{
    name = "book_desktop_panel",
    covers_fullscreen = true,
    desktop = nil,
}

local FIXED_ACTIONS = { "night", "wifi" }
local DEFAULT_CUSTOM_ACTIONS = { "native_menu" }

local ACTIONS = {
    night = {
        title = _("夜间模式"),
        icon = "dark_mode",
        fixed = true,
        active = function()
            return G_reader_settings:isTrue("night_mode")
        end,
        run = function()
            UIManager:broadcastEvent(Event:new("ToggleNightMode"))
        end,
    },
    wifi = {
        title = _("Wi-Fi"),
        icon = "wifi",
        fixed = true,
        available = function()
            return Device:hasWifiToggle()
        end,
        active = function()
            return NetworkMgr:isWifiOn()
        end,
        run = function()
            UIManager:broadcastEvent(Event:new("ToggleWifi"))
        end,
    },
    native_menu = {
        title = _("原生顶部面板"),
        icon = "menu",
        event = "ShowMenu",
    },
    rotate = {
        title = _("旋转屏幕"),
        icon = "screen_rotation",
        event = "IterateRotation",
    },
    refresh = {
        title = _("全屏刷新"),
        icon = "refresh",
        event = "FullRefresh",
    },
    frontlight = {
        title = _("前光开关"),
        icon = "brightness_6",
        event = "ToggleFrontlight",
        available = function()
            return Device:hasFrontlight()
        end,
    },
    suspend = {
        title = _("休眠"),
        icon = "bedtime",
        event = "RequestSuspend",
        available = function()
            return Device:canSuspend()
        end,
    },
}

local CUSTOM_ACTION_ORDER = { "native_menu", "rotate", "refresh", "frontlight", "suspend" }
local external_actions = {}
local external_order = {}
local ICON_CHOICES = {
    "menu", "dashboard", "settings", "extension", "apps", "home", "library_books",
    "folder", "sync", "refresh", "screen_rotation", "bedtime", "wifi", "dark_mode",
    "brightness_6", "book",
}

local function actionFor(id)
    return ACTIONS[id] or external_actions[id]
end

local function actionAvailable(action)
    if not action then return false end
    if not action.available then return true end
    local ok, available = pcall(action.available)
    if not ok then
        logger.err("book quick panel action availability failed:", available)
        return false
    end
    return available == true
end

local function actionActive(id, action)
    if not action or not action.active then return false end
    local ok, active = pcall(action.active)
    if not ok then
        logger.err("book quick panel action state failed:", id, active)
        return false
    end
    return active == true
end

local function configuredCustomActions()
    local configured = MoonSettings.get().quick_panel_actions
    if type(configured) ~= "table" then
        configured = DEFAULT_CUSTOM_ACTIONS
    end
    local seen, result = {}, {}
    for _, id in ipairs(configured) do
        local action = actionFor(id)
        if action and not action.fixed and not seen[id] then
            seen[id] = true
            result[#result + 1] = id
        end
    end
    return result
end

local function actionIcon(id, action)
    local overrides = MoonSettings.get().quick_panel_icons
    local icon = type(overrides) == "table" and overrides[id] or nil
    if type(icon) == "string" and icon ~= "" then return icon end
    return action.icon
end

local function saveCustomActions(ids)
    local settings = MoonSettings.get()
    settings.quick_panel_actions = ids
    MoonSettings.save(settings)
end

--- 返回可配置动作，设置页只依赖此稳定接口。
---@return table[]
function Panel.options()
    local enabled, options = {}, {}
    for position, id in ipairs(configuredCustomActions()) do
        enabled[id] = position
    end
    local ids = {}
    for _, id in ipairs(CUSTOM_ACTION_ORDER) do ids[#ids + 1] = id end
    for _, id in ipairs(external_order) do ids[#ids + 1] = id end
    for _, id in ipairs(ids) do
        local action = actionFor(id)
        options[#options + 1] = {
            id = id,
            title = action.title,
            icon = actionIcon(id, action),
            enabled = enabled[id] ~= nil,
            position = enabled[id],
            available = actionAvailable(action),
        }
    end
    return options
end

--- 注册其他插件提供的快捷动作。
--- callback 应自行打开页面或弹窗；异常只会禁用本次调用并写入日志。
---@param action table { id: string, title: string, icon: string, callback: fun(), available: fun():boolean|nil }
---@return boolean, string|nil
function Panel.registerAction(action)
    if type(action) ~= "table" or type(action.id) ~= "string" or action.id == ""
        or type(action.title) ~= "string" or action.title == ""
        or type(action.icon) ~= "string" or action.icon == ""
        or (action.available ~= nil and type(action.available) ~= "function")
        or type(action.callback) ~= "function" then
        return false, "action requires id, title, icon, callback, and optional available function"
    end
    if ACTIONS[action.id] or external_actions[action.id] then
        return false, "action id already registered"
    end
    external_actions[action.id] = action
    external_order[#external_order + 1] = action.id
    return true
end

--- 注销外部插件快捷动作；持久化配置保留，插件重新注册后自动恢复。
---@param id string
---@return boolean
function Panel.unregisterAction(id)
    if not external_actions[id] then return false end
    external_actions[id] = nil
    for i, current in ipairs(external_order) do
        if current == id then table.remove(external_order, i) break end
    end
    return true
end

--- 图标选择器的可选 Material Icons 名称。
---@return string[]
function Panel.iconChoices()
    return ICON_CHOICES
end

--- 保存某个可配置动作的图标覆盖值。
---@param id string
---@param icon string
function Panel.setIcon(id, icon)
    local action = actionFor(id)
    if not action or action.fixed or type(icon) ~= "string" or icon == "" then return end
    local settings = MoonSettings.get()
    settings.quick_panel_icons = type(settings.quick_panel_icons) == "table" and settings.quick_panel_icons or {}
    settings.quick_panel_icons[id] = icon
    MoonSettings.save(settings)
end

--- 已启用的可配置动作数量。
---@return number
function Panel.enabledCount()
    return #configuredCustomActions()
end

--- 启用或停用一个可配置动作。
---@param id string
---@param enabled boolean
function Panel.setEnabled(id, enabled)
    local action = actionFor(id)
    if not action or action.fixed then return end
    local ids, found = configuredCustomActions(), nil
    for i, current in ipairs(ids) do
        if current == id then
            found = i
            break
        end
    end
    if enabled and not found then
        ids[#ids + 1] = id
    elseif not enabled and found then
        table.remove(ids, found)
    end
    saveCustomActions(ids)
end

--- 在已启用动作中移动一位。
---@param id string
---@param delta number
function Panel.move(id, delta)
    local ids = configuredCustomActions()
    for i, current in ipairs(ids) do
        if current == id then
            local target = math.max(1, math.min(#ids, i + delta))
            if target ~= i then
                ids[i], ids[target] = ids[target], ids[i]
                saveCustomActions(ids)
            end
            return
        end
    end
end

local function rectContains(rect, pos)
    return rect and pos and pos.x >= rect.x and pos.x < rect.x + rect.w
        and pos.y >= rect.y and pos.y < rect.y + rect.h
end

local function actionTile(action, width, height, active, icon)
    local fg = Blitbuffer.COLOR_BLACK
    return Surface.pill(VerticalGroup:new{
                align = "center",
                Icon.widget{ name = icon or action.icon, size = 24, color = fg },
                VerticalSpan:new{ width = UI.sz(4) },
                TextWidget:new{
                    text = action.title,
                    face = UI.face("xx_smallinfofont", 12),
                    fgcolor = fg,
                    max_width = width - UI.sz(18),
                },
            }, {
        width = width,
        height = height,
        padding = UI.sz(5),
        background = active and UI.actionSurface() or UI.surface(),
        shadow = false,
    })
end

local function sliderRow(title, value, width)
    local label_w = UI.sz(72)
    local value_w = UI.sz(42)
    local bar_w = math.max(UI.sz(100), width - label_w - value_w - UI.sz(16))
    local row_h = UI.sz(42)
    local row = HorizontalGroup:new{
        align = "center",
        CenterContainer:new{
            dimen = Geom:new{ w = label_w, h = row_h },
            TextWidget:new{
                text = title,
                face = UI.face("cfont", 13),
                max_width = label_w,
            },
        },
        HorizontalSpan:new{ width = UI.sz(8) },
        UI.progressBar(bar_w, UI.sz(22), value),
        HorizontalSpan:new{ width = UI.sz(8) },
        CenterContainer:new{
            dimen = Geom:new{ w = value_w, h = row_h },
            TextWidget:new{
                text = string.format("%d%%", value),
                face = UI.face("xx_smallinfofont", 12),
                max_width = value_w,
            },
        },
    }
    return CenterContainer:new{
        dimen = Geom:new{ w = width, h = row_h },
        row,
    }, bar_w, label_w + UI.sz(8)
end

--- 初始化全屏输入层及面板布局。
function Panel:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self._closed = false
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
        Pan = { GestureRange:new{ ges = "pan", range = self.dimen } },
        PanRelease = { GestureRange:new{ ges = "pan_release", range = self.dimen } },
        Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    self:rebuild()
end

--- 当前设备上实际显示的快捷动作。
--- 原生菜单 Tab 和下拉面板共用此数据，避免两处各自判断能力和配置。
---@return table[]
function Panel.menuActions()
    local actions = {}
    for _, id in ipairs(FIXED_ACTIONS) do
        local action = actionFor(id)
        if actionAvailable(action) then
            actions[#actions + 1] = { id = id, title = action.title, active = actionActive(id, action) }
        end
    end
    for _, id in ipairs(configuredCustomActions()) do
        local action = actionFor(id)
        if actionAvailable(action) then
            actions[#actions + 1] = { id = id, title = action.title, active = actionActive(id, action) }
        end
    end
    return actions
end

--- 当前设备上实际显示的动作 id。
---@return string[]
function Panel:visibleActionIds()
    local ids = {}
    for _, action in ipairs(Panel.menuActions()) do
        ids[#ids + 1] = action.id
    end
    return ids
end

--- 从系统状态重建动作与滑杆。
function Panel:rebuild()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    local pad = UI.pagePad()
    local content_w = sw - pad * 2
    local action_ids = self:visibleActionIds()
    local max_columns = sw > sh and 6 or 4
    local columns = math.max(2, math.min(max_columns, #action_ids))
    local action_rows = math.max(1, math.ceil(#action_ids / columns))
    local gap = UI.sz(8)
    local tile_w = math.floor((content_w - gap * (columns - 1)) / columns)
    local tile_h = UI.sz(72)
    local actions_h = action_rows * tile_h + (action_rows - 1) * gap
    local powerd = Device:getPowerDevice()
    local has_light = Device:hasFrontlight()
    local has_warmth = Device:hasNaturalLight()
    local slider_h = UI.sz(42)
    local controls_h = (has_light and slider_h or 0) + (has_warmth and slider_h or 0)
    if controls_h > 0 then controls_h = controls_h + UI.sz(12) end
    local drawer_h = math.min(sh, pad * 2 + actions_h + controls_h + UI.sz(18))

    self._drawer_h = drawer_h
    self._action_rects = {}
    self._slider_rects = {}

    local action_group = VerticalGroup:new{ align = "left" }
    local action_row
    for i, id in ipairs(action_ids) do
        local column = (i - 1) % columns
        local row = math.floor((i - 1) / columns)
        if column == 0 then
            if action_row then
                table.insert(action_group, action_row)
                table.insert(action_group, VerticalSpan:new{ width = gap })
            end
            action_row = HorizontalGroup:new{ align = "center" }
        else
            table.insert(action_row, HorizontalSpan:new{ width = gap })
        end
        local action = actionFor(id)
        local active = actionActive(id, action)
        table.insert(action_row, actionTile(action, tile_w, tile_h, active, actionIcon(id, action)))
        self._action_rects[id] = Geom:new{
            x = pad + column * (tile_w + gap),
            y = pad + row * (tile_h + gap),
            w = tile_w,
            h = tile_h,
        }
    end
    if action_row then table.insert(action_group, action_row) end

    local content = VerticalGroup:new{ align = "left", action_group }
    local slider_y = pad + actions_h
    if controls_h > 0 then
        table.insert(content, VerticalSpan:new{ width = UI.sz(12) })
        slider_y = slider_y + UI.sz(12)
    end
    if has_light then
        local min, max = tonumber(powerd.fl_min) or 0, tonumber(powerd.fl_max) or 100
        local current = tonumber(powerd:frontlightIntensity()) or min
        local value = max > min and math.floor((current - min) * 100 / (max - min) + 0.5) or 0
        value = math.max(0, math.min(100, value))
        local row, bar_w, bar_x = sliderRow(_("亮度"), value, content_w)
        table.insert(content, row)
        self._slider_rects.brightness = Geom:new{ x = pad + bar_x, y = slider_y, w = bar_w, h = slider_h }
        slider_y = slider_y + slider_h
    end
    if has_warmth then
        local min = tonumber(powerd.fl_warmth_min) or 0
        local max = tonumber(powerd.fl_warmth_max) or 100
        local current = powerd:toNativeWarmth(powerd:frontlightWarmth())
        local value = max > min and math.floor((current - min) * 100 / (max - min) + 0.5) or 0
        value = math.max(0, math.min(100, value))
        local row, bar_w, bar_x = sliderRow(_("冷暖色调"), value, content_w)
        table.insert(content, row)
        self._slider_rects.warmth = Geom:new{ x = pad + bar_x, y = slider_y, w = bar_w, h = slider_h }
    end

    local drawer = FrameContainer:new{
        bordersize = 0,
        padding = pad,
        background = Blitbuffer.COLOR_WHITE,
        width = sw,
        height = drawer_h,
        dimen = Geom:new{ w = sw, h = drawer_h },
        content,
    }
    local handle = CenterContainer:new{
        dimen = Geom:new{ w = sw, h = UI.sz(18) },
        LineWidget:new{
            background = UI.rule(),
            dimen = Geom:new{ w = UI.sz(48), h = UI.sz(3) },
        },
    }
    handle.overlap_offset = { 0, drawer_h - UI.sz(18) }
    drawer.overlap_offset = { 0, 0 }
    local outside = LineWidget:new{
        background = Blitbuffer.COLOR_LIGHT_GRAY,
        dimen = Geom:new{ w = sw, h = math.max(1, sh - drawer_h) },
    }
    outside.overlap_offset = { 0, drawer_h }
    self[1] = OverlapGroup:new{
        dimen = Geom:new{ w = sw, h = sh },
        outside,
        drawer,
        handle,
    }
    UIManager:setDirty(self, "ui")
end

--- 关闭面板并恢复桌面刷新。
function Panel:close()
    if self._closed then return end
    self._closed = true
    UIManager:close(self)
    if self.desktop then
        self.desktop.panel = nil
        if not self.desktop._closed then
            self.desktop:refreshTopBar()
            UIManager:setDirty(self.desktop, "ui")
        end
    end
end

--- 执行快捷动作；下拉面板和原生菜单 Tab 共享执行语义。
---@param id string
---@param opts table|nil { close: fun()|nil, refresh: fun()|nil }
---@return boolean
function Panel.executeAction(id, opts)
    opts = opts or {}
    local action = actionFor(id)
    if not action or not actionAvailable(action) then return false end
    if ACTIONS[id] == action and action.run then
        action.run()
        if opts.refresh then
            UIManager:nextTick(opts.refresh)
            if id == "wifi" then UIManager:scheduleIn(1, opts.refresh) end
        end
        return true
    end
    if opts.close then opts.close() end
    if action.event then
        UIManager:broadcastEvent(Event:new(action.event))
        return true
    end
    local ok, err = pcall(action.callback)
    if not ok then logger.err("book quick panel action failed:", id, err) end
    return ok
end

--- 在下拉面板中执行快捷动作。
---@param id string
function Panel:runAction(id)
    local function refreshState()
        if self._closed then return end
        self:rebuild()
        if self.desktop and not self.desktop._closed then self.desktop:refreshTopBar() end
    end
    return Panel.executeAction(id, {
        close = function() self:close() end,
        refresh = refreshState,
    })
end

--- 按 0..1 比例设置亮度或暖度。
---@param kind "brightness"|"warmth"
---@param fraction number
---@return boolean
function Panel.setLevel(kind, fraction)
    fraction = math.max(0, math.min(1, tonumber(fraction) or 0))
    local powerd = Device:getPowerDevice()
    if kind == "brightness" then
        local min, max = tonumber(powerd.fl_min) or 0, tonumber(powerd.fl_max) or 100
        local native = math.floor(min + fraction * (max - min) + 0.5)
        if native <= min then
            powerd:turnOffFrontlight()
        else
            powerd:setIntensity(native)
        end
        powerd:updateResumeFrontlightState()
    elseif kind == "warmth" then
        local min = tonumber(powerd.fl_warmth_min) or 0
        local max = tonumber(powerd.fl_warmth_max) or 100
        local native = math.floor(min + fraction * (max - min) + 0.5)
        powerd:setWarmth(powerd:fromNativeWarmth(native))
    else
        return false
    end
    return true
end

--- 根据触摸位置设置亮度或暖度。
---@param kind "brightness"|"warmth"
---@param pos table
---@param force_refresh boolean|nil
---@return boolean
function Panel:setSlider(kind, pos, force_refresh)
    local rect = self._slider_rects[kind]
    if not rect or not pos then return false end
    if not Panel.setLevel(kind, (pos.x - rect.x) / rect.w) then return false end
    local now = os.clock()
    if force_refresh or not self._last_slider_refresh or now - self._last_slider_refresh >= 0.12 then
        self._last_slider_refresh = now
        self:rebuild()
        if self.desktop and not self.desktop._closed then self.desktop:refreshTopBar() end
    end
    return true
end

---@param _ any
---@param ges table|nil
---@return boolean
function Panel:onTap(_, ges)
    if not ges or not ges.pos then return true end
    if ges.pos.y >= self._drawer_h then
        self:close()
        return true
    end
    for id, rect in pairs(self._action_rects) do
        if rectContains(rect, ges.pos) then
            self:runAction(id)
            return true
        end
    end
    for kind, rect in pairs(self._slider_rects) do
        if rectContains(rect, ges.pos) then
            self:setSlider(kind, ges.pos, true)
            return true
        end
    end
    return true
end

---@param _ any
---@param ges table|nil
---@return boolean
function Panel:onPan(_, ges)
    if not ges or not ges.pos then return true end
    for kind, rect in pairs(self._slider_rects) do
        if rectContains(rect, ges.pos) then
            self._active_slider = kind
            self:setSlider(kind, ges.pos, false)
            return true
        end
    end
    if self._active_slider then
        self:setSlider(self._active_slider, ges.pos, false)
    end
    return true
end

---@param _ any
---@param ges table|nil
---@return boolean
function Panel:onPanRelease(_, ges)
    if self._active_slider and ges and ges.pos then
        self:setSlider(self._active_slider, ges.pos, true)
    end
    self._active_slider = nil
    return true
end

---@param _ any
---@param ges table|nil
---@return boolean
function Panel:onSwipe(_, ges)
    if ges and ges.direction == "north" then self:close() end
    return true
end

function Panel:onCloseWidget()
    self._closed = true
    if self.desktop and self.desktop.panel == self then self.desktop.panel = nil end
end

return Panel
