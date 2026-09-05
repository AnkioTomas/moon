--[[--
Desktop 顶部状态条（纯构建、无内部状态）。

布局：
  +---------------------------------------------------+
  | 12:00  [源] 源名              内存  存储  Wi‑Fi  ☀  🔋 |
  |───────────────────────────────────────────────────|
  +---------------------------------------------------+
  左贴左（时钟最左，其后源名）· 右贴右（OverlapGroup）；缺能力的指标直接省略。

指标（右，左→右）：
  剩余内存、后台缓存（有任务时显示且可点击）、剩余存储、Wi‑Fi、亮度、电池（电池固定贴最右）。
  内存/存储用 util.getFriendlySize 显示可用量；拉不到则省略。

电池：
  未充电使用竖向 battery_android_0..6/full；充电按电量使用对应的 charging 图标；
  字形来自 Google Material Symbols Outlined。
  图标与电量百分比始终成对显示。

状态如何更新（本文件不负责）：
  TopBar.build() 每次从 Device / NetworkMgr / settings 现读。
  Desktop:rebuild() 会整页重建并再次调用 TopBar.build()。
  定时：Desktop:scheduleClockTick() 每分钟只调用 refreshTopBar()（换顶栏 + 区域 ui 刷新，不整页 rebuild）。
  事件：切源、切 tab、设置改完、封面 idle 回调等凡触发 rebuild 的路径也会刷新顶栏。
  交互：本组件仍只负责展示；Desktop 在顶栏高度范围注册点击和向下滑手势，
  源名区域命中由 TopBar.sourceTapRect() 提供。

@module koplugin.book.ui.components.topbar
--]]

local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local datetime = require("datetime")
local NetworkMgr = require("ui/network/manager")
local ffiUtil = require("ffi/util")
local util = require("util")
local _ = require("gettext")
local Screen = Device.screen

local UI = require("ui.components.bookui")
local Icon = require("ui.components.icon")
local MoonSettings = require("utils.settings")
local SourceRegistry = require("source.registry")
local CacheQueue = require("source.cache_queue")

local TopBar = {}
local cache_rect
local source_rect

--- 顶栏小图标逻辑尺寸（小于底栏的 24）。
local ICON_SIZE = 14

--- 顶栏项目是否显示。缺失或损坏的旧配置按显示处理，保持升级前行为。
---@param id string
---@return boolean
local function visible(id)
    local home = MoonSettings.get("home")
    local items = type(home.home_topbar_items) == "table" and home.home_topbar_items or {}
    return items[id] ~= false
end

--- 通用「图标 + 文案」指标行；text 空则整项省略。
---@param icon_name string
---@param text string|nil
---@return table|nil
local function metric(icon_name, text)
    if not text or text == "" then
        return nil
    end
    return Icon.label{
        name = icon_name,
        text = text,
        size = ICON_SIZE,
        font_size = 12,
        gap = UI.sz(3),
    }
end

--- 电池图标：非充电使用 battery_android_0..6/full，充电使用电量档位图标。
---@param pct number
---@param charging boolean|nil
---@return string
local function batteryIconName(pct, charging)
    if charging then
        if pct <= 20 then return "battery_charging_20_2" end
        if pct <= 30 then return "battery_charging_30_2" end
        if pct <= 50 then return "battery_charging_50_2" end
        if pct <= 60 then return "battery_charging_60_2" end
        if pct <= 80 then return "battery_charging_80_2" end
        return "battery_android_bolt"
    end
    if pct >= 100 then
        return "battery_android_full"
    end
    return "battery_android_" .. tostring(math.min(6, math.floor(pct * 7 / 100)))
end

--- 电池指标：竖向电池图标 + 电量百分比（pct 钳制一次，图标与文字共用）。
---@param pct number
---@param charging boolean|nil
---@return table
local function batteryMetric(pct, charging)
    pct = math.max(0, math.min(100, tonumber(pct) or 0))
    return Icon.label{
        name = batteryIconName(pct, charging),
        text = string.format("%d%%", math.floor(pct + 0.5)),
        size = ICON_SIZE,
        font_size = 12,
        gap = UI.sz(3),
    }
end

--- 当前活跃源显示名（只取 meta，不构造 Source 实例）。
---@return string
local function sourceName()
    local id = MoonSettings.activeSourceId()
    local meta = id and SourceRegistry.meta(id)
    if meta then
        return meta.name or meta.id
    end
    return id or _("未知源")
end

--- 后台全本缓存状态；无任务时不占顶栏空间。
---@return string|nil
local function cacheStatus()
    local status = CacheQueue.status()
    if not status then return nil end
    if status.state == "retry_wait" then
        return _("缓存重试中")
    end
    if status.total > 0 then
        return _("缓存") .. " " .. tostring(status.cached) .. "/" .. tostring(status.total)
    end
    return _("缓存中")
end

--- 当前源标签在屏幕上的可点区域。
---@return table|nil
function TopBar.sourceTapRect()
    return source_rect
end

--- 当前缓存指标在顶栏上的可点区域；无任务时返回 nil。
---@return table|nil
function TopBar.cacheTapRect()
    return cache_rect
end

--- 构建一整条顶栏 widget（无缓存；调用方负责挂到 Desktop 并 setDirty）。
---@return table
function TopBar.build()
    local sw = Screen:getWidth()
    local th = UI.topBarH()
    local pad = UI.pagePad()
    local gap_w = UI.sz(8)
    local line_h = UI.line()
    local inner_h = th - line_h
    local inner_w = sw - pad * 2

    -- 左：时钟最左，其后当前源（过长截断）。
    local left = HorizontalGroup:new{ align = "center" }
    local left_w = 0
    if visible("clock") then
        local clock = TextWidget:new{
            text = datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock")),
            face = UI.face("xx_smallinfofont", 12),
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        table.insert(left, clock)
        local size = clock:getSize()
        left_w = size and size.w or 0
    end
    source_rect = nil
    if visible("source") then
        if #left > 0 then
            table.insert(left, HorizontalSpan:new{ width = gap_w })
            left_w = left_w + gap_w
        end
        local source = Icon.label{
            name = "source",
            text = sourceName(),
            size = ICON_SIZE,
            font_size = 12,
            gap = UI.sz(4),
            max_width = math.floor(inner_w * 0.36),
        }
        table.insert(left, source)
        local size = source:getSize()
        if size then
            source_rect = Geom:new{ x = pad + left_w, y = 0, w = size.w, h = th }
        end
    end

    -- 右：剩余内存、后台缓存、剩余存储、Wi-Fi、亮度、电池（电池贴最右）。
    local right = HorizontalGroup:new{ align = "center" }
    local n = 0
    local metrics = {}
    --- 向右侧指标行追加一项。
    ---@param widget table|nil
    local function add(widget)
        if not widget then
            return
        end
        if n > 0 then
            table.insert(right, HorizontalSpan:new{ width = gap_w })
        end
        table.insert(right, widget)
        metrics[#metrics + 1] = widget
        n = n + 1
    end

    -- 剩余内存（calcFreeMem 返回字节；macOS 模拟器无 /proc/meminfo 则省略）。
    if visible("memory") then
        local mem_avail = util.calcFreeMem()
        if mem_avail then
            add(metric("memory", util.getFriendlySize(mem_avail)))
        end
    end

    local cache_widget
    if visible("cache") then
        cache_widget = metric("download", cacheStatus())
    end
    add(cache_widget)

    -- 剩余存储：数据目录所在文件系统的可用空间（f_bavail；接口在 ffi/util）。
    if visible("storage") then
        local _, _, disk_avail = ffiUtil.df(DataStorage:getDataDir())
        if disk_avail then
            add(metric("hard_drive", util.getFriendlySize(disk_avail)))
        end
    end

    if visible("wifi") then
        local wifi_on = NetworkMgr:isWifiOn()
        add(Icon.widget{ name = wifi_on and "wifi" or "wifi_off", size = ICON_SIZE })
    end

    if visible("brightness")
        and Device:hasFrontlight() and Device.powerd and Device.powerd.frontlightIntensity
    then
        local lvl = Device.powerd:frontlightIntensity()
        if type(lvl) == "number" then
            add(metric("brightness_6", string.format("%d%%", lvl)))
        end
    end

    if visible("battery") and Device:hasBattery() and Device.powerd then
        local pct = Device.powerd:getCapacity()
        if type(pct) == "number" then
            add(batteryMetric(pct, Device.powerd:isCharging()))
        end
    end

    cache_rect = nil
    local right_w = 0
    for i, widget in ipairs(metrics) do
        local size = widget.getSize and widget:getSize()
        if size then
            if i > 1 then right_w = right_w + gap_w end
            right_w = right_w + size.w
        end
    end
    for i, widget in ipairs(metrics) do
        if widget == cache_widget then
            local size = widget.getSize and widget:getSize()
            local before = 0
            for j = 1, i - 1 do
                local prev = metrics[j]
                local prev_size = prev.getSize and prev:getSize()
                if prev_size then before = before + prev_size.w + gap_w end
            end
            if size then
                cache_rect = Geom:new{
                    x = pad + inner_w - right_w + before,
                    y = 0,
                    w = size.w,
                    h = th,
                }
            end
            break
        end
    end

    -- 左右叠在同一行：左贴左、右贴右
    local row = OverlapGroup:new{
        dimen = Geom:new{ w = inner_w, h = inner_h },
        LeftContainer:new{
            dimen = Geom:new{ w = inner_w, h = inner_h },
            left,
        },
        RightContainer:new{
            dimen = Geom:new{ w = inner_w, h = inner_h },
            right,
        },
    }

    -- 分割线通栏；内容区用 HorizontalSpan 做左右 pad（避免内层再套白 Frame）
    return FrameContainer:new{
        bordersize = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = sw, h = th },
        VerticalGroup:new{
            align = "left",
            HorizontalGroup:new{
                HorizontalSpan:new{ width = pad },
                row,
                HorizontalSpan:new{ width = pad },
            },
            LineWidget:new{
                background = UI.rule(),
                dimen = Geom:new{ w = sw, h = line_h },
            },
        },
    }
end

return TopBar
