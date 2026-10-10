--[[--
桌面顶栏：左时钟 / 源名，右内存 / 后台任务 / 存储 / Wi‑Fi / 亮度 / 电量。

  +---------------------------------------------------+
  | 12:00  [源] 源名          内存  任务  存储  Wi‑Fi  ☀  🔋 |
  +---------------------------------------------------+

每项是数据（见 BookTopBarItem）：read() 给 text, icon，都空则不显示。
读数任一变化就整条重建、只刷顶栏这一条；定时器与订阅归顶栏，恢复时挂、暂停时拆。
点按：有 tap 的项优先（子控件先收事件），其余位置打开快捷面板。

@module koplugin.book.desktop.topbar
--]]

local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local Device = require("device")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local MoonSettings = require("utils.settings")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local SourceRegistry = require("source.registry")
local TaskDialog = require("workers.ui.task_dialog")
local Tasks = require("workers.tasks")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local datetime = require("datetime")
local ffiUtil = require("ffi/util")
local util = require("util")
local Theme = require("ui.themes")
local Icon = require("ui.themes.widgets.icon")
local Tap = require("ui.themes.widgets.tap")
local Text = require("ui.themes.widgets.text")
local _ = require("gettext")

---@class BookTopBarItem
---@field id string 顶栏项标识，也是 home_topbar_items 的设置键
---@field read fun(): string|nil, string|nil 当前文字与图标名
---@field align "left"|nil left 进左组，其余进右组
---@field minute boolean|nil 需要轮询：打开时顶栏挂一个分钟对齐的心跳（每跳重读全部项）
---@field events table<string, boolean>|nil 触发重读的桌面事件
---@field watch? fun(cb: fun()): CancelHandle 订阅变化，返回 { cancel }
---@field tap fun(desktop: BookDesktop)|nil 点按动作
---@field max_ratio number|nil 占顶栏宽度的上限比例

--- 非充电用 battery_android_0..6 / full，充电用电量档位图标。
---@param pct number 电量百分比 0..100
---@param charging boolean|nil
---@return string
local function batteryIcon(pct, charging)
    if charging then
        if pct <= 20 then return "battery_charging_20_2" end
        if pct <= 30 then return "battery_charging_30_2" end
        if pct <= 50 then return "battery_charging_50_2" end
        if pct <= 60 then return "battery_charging_60_2" end
        if pct <= 80 then return "battery_charging_80_2" end
        return "battery_android_bolt"
    end
    if pct >= 100 then return "battery_android_full" end
    return "battery_android_" .. tostring(math.min(6, math.floor(pct * 7 / 100)))
end

---@type BookTopBarItem[]
local ITEMS = {
    {
        id = "clock",
        align = "left",
        minute = true,
        read = function()
            return datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock")) --[[@as string]]
        end,
    },
    {
        id = "source",
        align = "left",
        max_ratio = 0.36,
        read = function()
            if MoonSettings.get("source").library_mixed then return _("混合模式"), "source" end
            local id = SourceRegistry.activeId()
            local meta = id and SourceRegistry.meta(id)
            return meta and (meta.name or meta.id) or id or _("未知源"), "source"
        end,
        tap = function(desktop)
            desktop.settings.source:pickActive()
        end,
    },
    {
        id = "memory",
        interval = 120,
        read = function()
            local avail = util.calcFreeMem()
            if avail == nil then return nil end
            return util.getFriendlySize(avail), "memory"
        end,
    },
    {
        id = "cache",
        max_ratio = 0.4,
        watch = Tasks.watch,
        read = function()
            local tasks = Tasks.tasks()
            local task = tasks[1]
            if not task then return nil, "download" end
            local text = TaskDialog.label(task.kind) .. " " .. TaskDialog.status(task, true)
            if #tasks > 1 then text = text .. " +" .. tostring(#tasks - 1) end
            return text, "download"
        end,
        tap = function()
            TaskDialog:new{}:show()
        end,
    },
    {
        id = "storage",
        interval = 600,
        read = function()
            local _total, _used, avail = ffiUtil.df(DataStorage:getDataDir())
            if avail == nil then return nil end
            return util.getFriendlySize(avail), "hard_drive"
        end,
    },
    {
        id = "wifi",
        events = { NetworkConnected = true, NetworkDisconnected = true },
        read = function()
            return nil, require("ui/network/manager"):isWifiOn() and "wifi" or "wifi_off"
        end,
    },
    {
        id = "brightness",
        events = { FrontlightStateChanged = true },
        read = function()
            if not Device:hasFrontlight() then return nil end
            return string.format("%d%%", require("features.panel.desktop").lightPercent("brightness")), "brightness_6"
        end,
    },
    {
        id = "battery",
        interval = 600,
        events = { Charging = true, NotCharging = true },
        read = function()
            if not (Device:hasBattery() and Device.powerd) then return nil end
            local pct = Device.powerd:getCapacity()
            if type(pct) ~= "number" then return nil end
            pct = math.max(0, math.min(100, pct))
            return string.format("%d%%", math.floor(pct + 0.5)), batteryIcon(pct, Device.powerd:isCharging())
        end,
    },
}
--- 顶栏在桌面控件树里的节点：KOReader 广播沿树下发，按各项声明的 events 直接重读。
--- 处理函数必须返回 nil：返回 true 会截断同层后续控件（底栏）收到这条广播。
local BarWidget = WidgetContainer:extend{}
for _idx, item in ipairs(ITEMS) do
    for event in pairs(item.events or {}) do
        BarWidget["on" .. event] = function(self) self.bar:refresh() end
    end
end

local ICON_SIZE = 14

---@class BookTopBar
---@field desktop BookDesktop
---@field active boolean 已挂定时器 / 订阅
---@field key string|nil 当前画面的读数签名
---@field handles CancelHandle[] 定时器与订阅
local TopBar = {}
TopBar.__index = TopBar

--- 按 id 取顶栏项（测试读单项）。
---@param id string
---@return BookTopBarItem|nil
function TopBar.find(id)
    for _idx, item in ipairs(ITEMS) do
        if item.id == id then return item end
    end
end

---@param opts { desktop: BookDesktop }
---@return BookTopBar
function TopBar:new(opts)
    ---@type BookTopBar
    local bar = setmetatable(opts, self)
    bar.active = false
    bar.handles = {}
    return bar
end

--- 顶栏高度（物理像素）。
---@return number
function TopBar.height()
    return Theme.px(Theme.current().control.height)
end

--- 顶栏项是否打开；缺失或损坏的旧配置按显示处理。
---@param id string
---@return boolean
function TopBar.visible(id)
    local items = MoonSettings.get("desktop").home_topbar_items
    return type(items) ~= "table" or items[id] ~= false
end

--- 单项控件：图标 + 文字 / 只有图标 / 只有文字。
---@param text string|nil
---@param icon string|nil
---@param max_width number|nil
---@return table
function TopBar.metric(text, icon, max_width)
    local t = Theme.current()
    local ink = Blitbuffer.Color8(t.color.ink)
    if icon and text then
        return Icon.label{ name = icon, text = text, size = ICON_SIZE, color = ink,
            font_size = t.font.caption, gap = Theme.px(t.space.xs), max_width = max_width }
    end
    if icon then return Icon.widget{ name = icon, size = ICON_SIZE, color = ink } end
    ---@cast text string
    return Text.line("caption", text)
end

--- 左组贴左、右组贴右，两侧各留 space.lg。
---@param width number
---@param height number
---@param left table[]
---@param right table[]
---@return table
function TopBar.row(width, height, left, right)
    local t = Theme.current()
    local pad, gap = Theme.px(t.space.lg), Theme.px(t.space.sm)
    local inner_w = math.max(1, width - pad * 2)
    local function group(widgets)
        local g = HorizontalGroup:new{ align = "center" }
        for i, w in ipairs(widgets) do
            if i > 1 then g[#g + 1] = HorizontalSpan:new{ width = gap } end
            g[#g + 1] = w
        end
        return g
    end
    return HorizontalGroup:new{
        HorizontalSpan:new{ width = pad },
        OverlapGroup:new{
            dimen = Geom:new{ w = inner_w, h = height },
            LeftContainer:new{ dimen = Geom:new{ w = inner_w, h = height }, group(left) },
            RightContainer:new{ dimen = Geom:new{ w = inner_w, h = height }, group(right) },
        },
        HorizontalSpan:new{ width = pad },
    }
end

--- 当前显示的各项读数（关掉的项与空读数跳过）及其签名。
---@return table[] shown { item, text, icon }
---@return string key
local function readAll()
    local shown, key = {}, {}
    for _idx, item in ipairs(ITEMS) do
        if TopBar.visible(item.id) then
            local text, icon = item.read()
            if text == "" then text = nil end
            if text or icon then
                shown[#shown + 1] = { item = item, text = text, icon = icon }
                key[#key + 1] = item.id .. "=" .. tostring(icon) .. ":" .. tostring(text)
            end
        end
    end
    return shown, table.concat(key, "\31")
end

--- 按当前读数新建整条顶栏。
---@param width number
---@return table
function TopBar:build(width)
    local desktop = self.desktop
    local shown
    shown, self.key = readAll()
    local left, right = {}, {}
    for _idx, s in ipairs(shown) do
        local item = s.item
        local widget = TopBar.metric(s.text, s.icon, item.max_ratio and math.floor(width * item.max_ratio))
        if item.tap then widget = Tap.wrap(widget, function() item.tap(desktop) end) end
        local side = item.align == "left" and left or right
        side[#side + 1] = widget
    end
    return BarWidget:new{
        bar = self,
        Tap.wrap(TopBar.row(width, TopBar.height(), left, right), function()
            require("features.panel.native").show("desktop")
        end),
    }
end

--- 读数变了才让桌面换顶栏槽。
function TopBar:refresh()
    if not self.active then return end
    local _shown, key = readAll()
    if key ~= self.key then self.desktop:updateTopbar() end
end

--- 距下一分钟边界的秒数（1..61）。
---@return number
local function untilNextMinute()
    return 61 - tonumber(os.date("%S"))
end

--- 分钟对齐的心跳：refresh 每次重读全部项，一个定时器就够。
---@param self BookTopBar
local function schedule(self)
    local function tick()
        self:refresh()
        UIManager:scheduleIn(untilNextMinute(), tick)
    end
    UIManager:scheduleIn(untilNextMinute(), tick)
    self.handles[#self.handles + 1] = { cancel = function() UIManager:unschedule(tick) end }
end

--- 挂上心跳（有打开的轮询项时）与订阅并立即重读；已挂则只重读。
function TopBar:activate()
    if not self.active then
        self.active = true
        local poll = false
        for _idx, item in ipairs(ITEMS) do
            if TopBar.visible(item.id) then
                poll = poll or item.minute == true
                if item.watch then self.handles[#self.handles + 1] = item.watch(function() self:refresh() end) end
            end
        end
        if poll then schedule(self) end
    end
    self:refresh()
end

function TopBar:deactivate()
    self.active = false
    for _idx, handle in ipairs(self.handles) do handle:cancel() end
    self.handles = {}
end

TopBar.destroy = TopBar.deactivate

--- 设置开关 / 换源：重挂定时与订阅后重读。电源 / 网络 / 前光由 BarWidget 直接收广播。
---@param event string
function TopBar:onEvent(event)
    if (event == "topbar_changed" or event == "source_changed") and self.active then
        self:deactivate()
        self:activate()
    end
end

return TopBar
