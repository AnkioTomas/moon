--[[--
桌面顶栏：左时钟 / 源名，右内存 / 后台任务 / 存储 / Wi‑Fi / 亮度 / 电量，之后是各 feature 的项。

  +---------------------------------------------------+
  | 12:00  [源] 源名          内存  任务  存储  Wi‑Fi  ☀  🔋 |
  +---------------------------------------------------+

每项是数据（见 BookTopBarItem）：read() 给 text, icon，都空则不显示。
读数任一变化就整条重建、只刷顶栏这一条；定时器与订阅归顶栏，恢复时挂、暂停时拆。
点按：有 tap 的项优先（子控件先收事件），其余位置打开快捷面板。

其它顶栏项经扩展点 `topbar.items`（utils.extension）登记：每项是 `fn() → BookTopBarItem[]`，
首次用到时按登记顺序收集，追加在核心项之后（after 指定插位）。id 不能和核心项、其它项重复。
前光读数经单一提供者扩展点 `topbar.light_percent` 取；点空白处开快捷面板经 `quickpanel.show`。
第三方扩展的项（utils.external.collect("topbar")）再排在后面：id 自动加 `<扩展 id>.` 前缀，read / watch / tap 经 External.wrap 隔离，
缺 id / read / label、撞名只记日志跳过；插件没加载完时不缓存。已保存的 home_topbar_items 里多出的 id 无害。
顶层不要 require 重模块，放进 read / watch / tap 里延迟加载。设置页与预览读同一份数据，不用再登记。

@module koplugin.book.desktop.topbar
--]]

local DataStorage = require("datastorage")
local Device = require("device")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local MoonSettings = require("utils.settings")
local Ext = require("utils.extension")
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
---@field label string 设置页标题
---@field icon string 设置页行图标
---@field sample string|nil 设置页预览的样例文字
---@field bar_icon string|nil 设置页预览画的图标
---@field after string|nil 功能项插到这个 id 之后（缺失则排末尾）

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
        label = _("时钟"), icon = "schedule", sample = "12:34",
        align = "left",
        minute = true,
        read = function()
            return datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock")) --[[@as string]]
        end,
    },
    {
        id = "source",
        label = _("数据源"), icon = "source", sample = _("本地"), bar_icon = "source",
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
        label = _("剩余内存"), icon = "memory", sample = "128M", bar_icon = "memory",
        interval = 120,
        read = function()
            local avail = util.calcFreeMem()
            if avail == nil then return nil end
            return util.getFriendlySize(avail), "memory"
        end,
    },
    {
        id = "cache",
        label = _("后台任务"), icon = "download", sample = "1/3", bar_icon = "download",
        max_ratio = 0.4,
        watch = Tasks.watch,
        read = function()
            local tasks = Tasks.tasks()
            if #tasks == 0 then return _("空闲"), "download" end
            local running = 0
            for _idx, task in ipairs(tasks) do
                if task.state == "running" then running = running + 1 end
            end
            return running .. "/" .. #tasks, "download"
        end,
        tap = function()
            TaskDialog:new{}:show()
        end,
    },
    {
        id = "storage",
        label = _("剩余存储"), icon = "hard_drive", sample = "2.1G", bar_icon = "hard_drive",
        interval = 600,
        read = function()
            -- 旧版 KOReader 的 df 只返回 total, free，没有第三个 available
            local total, free, avail = ffiUtil.df(DataStorage:getDataDir())
            if not total then return nil end
            ---@cast free number
            avail = avail or free
            if avail == nil then return nil end
            return util.getFriendlySize(avail), "hard_drive"
        end,
    },
    {
        id = "wifi",
        label = _("Wi-Fi"), icon = "wifi", bar_icon = "wifi",
        events = { NetworkConnected = true, NetworkDisconnected = true },
        read = function()
            return nil, require("ui/network/manager"):isWifiOn() and "wifi" or "wifi_off"
        end,
    },
    {
        id = "brightness",
        label = _("亮度"), icon = "brightness_6", sample = "40%", bar_icon = "brightness_6",
        events = { FrontlightStateChanged = true },
        read = function()
            if not Device:hasFrontlight() then return nil end
            return string.format("%d%%", Ext.call("topbar.light_percent", "brightness") or 0), "brightness_6"
        end,
    },
    {
        id = "battery",
        label = _("电池"), icon = "battery_android_full", sample = "85%", bar_icon = "battery_android_full",
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

---@param self table
local function onBarEvent(self) self.bar:refresh() end

local ICON_SIZE = 14

---@class BookTopBar
---@field desktop BookDesktop
---@field active boolean 已挂定时器 / 订阅
---@field key string|nil 当前画面的读数签名
---@field handles CancelHandle[] 定时器与订阅
local TopBar = {}
TopBar.__index = TopBar

---@type BookTopBarItem[]|nil
local all_items

--- 全部顶栏项：核心项后接 features/<name>/topbar.lua 的项；首次调用时收集并把各项 events 挂到 BarWidget。
---@return BookTopBarItem[]
function TopBar.items()
    if all_items then return all_items end
    local items = { unpack(ITEMS) }
    local Hooks = require("utils.external")
    for _idx, source in ipairs(Ext.list("topbar.items")) do
        for _i, item in ipairs(source()) do
            local at = #items + 1
            for i, it in ipairs(items) do
                if it.id == item.after then at = i + 1 end
            end
            table.insert(items, at, item)
        end
    end
    local seen = {}
    for _idx, item in ipairs(items) do seen[item.id] = true end
    local ext_items, ready = Hooks.collect("topbar")
    for _idx, ext in ipairs(ext_items) do
        local list = Hooks.try(ext.id .. " topbar", ext.mod.items)
        for _i, raw in ipairs(type(list) == "table" and list or {}) do
            local id = type(raw) == "table" and Hooks.prefix(ext.id, raw.id)
            if not id or type(raw.read) ~= "function" or not raw.label or seen[id] then
                require("utils.log").err("feature external topbar rejected", ext.id, id)
            else
                local label = "topbar " .. id
                local item = {}
                for key, value in pairs(raw) do item[key] = value end
                item.id, item.after = id, nil
                item.read = Hooks.wrap(label, raw.read)
                item.watch = Hooks.wrap(label, raw.watch)
                item.tap = Hooks.wrap(label, raw.tap)
                seen[id] = true
                items[#items + 1] = item
            end
        end
    end
    for _idx, item in ipairs(items) do
        for event in pairs(item.events or {}) do BarWidget["on" .. event] = onBarEvent end
    end
    if ready then all_items = items end
    return items
end

--- 按 id 取顶栏项（测试读单项）。
---@param id string
---@return BookTopBarItem|nil
function TopBar.find(id)
    for _idx, item in ipairs(TopBar.items()) do
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
    local ink = Theme.color(t.color.icons)
    if icon and text then
        return Icon.label{ name = icon, text = text, size = ICON_SIZE, color = ink,
            text_color = Theme.color(t.color.ink),
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
    for _idx, item in ipairs(TopBar.items()) do
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
            Ext.call("quickpanel.show", "desktop")
        end),
    }
end

--- 读数变了才让桌面换顶栏槽。
function TopBar:refresh()
    if not self.active then return end
    local _shown, key = readAll()
    if key ~= self.key then self.desktop:updateTopbar() end
end

local WAKE_RECHECK = 5

--- 距下一分钟边界的秒数（1..61）。
---@return number
local function untilNextMinute()
    return 61 - tonumber(os.date("%S"))
end

--- 分钟对齐的心跳：refresh 每次重读全部项，一个定时器就够。
---@param self BookTopBar
local function schedule(self)
    local tick
    tick = require("ui.guard").wrap("topbar tick", function()
        self:refresh()
        UIManager:scheduleIn(untilNextMinute(), tick)
    end)
    UIManager:scheduleIn(untilNextMinute(), tick)
    self.handles[#self.handles + 1] = { cancel = function() UIManager:unschedule(tick) end }
end

--- 挂上心跳（有打开的轮询项时）与订阅并立即重读；已挂则只重读。
function TopBar:activate()
    if not self.active then
        self.active = true
        local poll = false
        for _idx, item in ipairs(TopBar.items()) do
            if TopBar.visible(item.id) then
                poll = poll or item.minute == true
                if item.watch then self.handles[#self.handles + 1] = item.watch(function() self:refresh() end) end
            end
        end
        if poll then schedule(self) end
    end
    self:refresh()
    -- 唤醒瞬间 Wi-Fi 还在重连，读到的是旧状态；稍后补读一次。
    if self.recheck then
        UIManager:unschedule(self.recheck)
    else
        self.recheck = function() self:refresh() end
    end
    UIManager:scheduleIn(WAKE_RECHECK, self.recheck)
end

function TopBar:deactivate()
    self.active = false
    if self.recheck then UIManager:unschedule(self.recheck) end
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
