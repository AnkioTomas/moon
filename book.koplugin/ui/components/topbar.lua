--[[--
Desktop 顶部状态条（纯构建、无内部状态）。

布局：
  左 — 当前活跃源（图标 + 名）
  右 — 监控指标：可用内存 / 电池 / 前光 / Wi‑Fi / 时钟
  底 — 通栏分割线

电池：
  5 段填充；低电（≤15% 且未充）黑底白格；充电时外壳浅底、文案前加「+」。
  墨水屏上靠「整格点亮/熄灭」看变化，不靠灰阶渐变。

状态如何更新（本文件不负责）：
  TopBar.build() 每次从 Device / NetworkMgr / settings 现读。
  Desktop:rebuild() 会整页重建并再次调用 TopBar.build()。
  定时：Desktop:scheduleClockTick() 每分钟只调用 refreshTopBar()（换顶栏 + 区域 ui 刷新，不整页 rebuild）。
  事件：切源、切 tab、设置改完、封面 idle 回调等凡触发 rebuild 的路径也会刷新顶栏。
  交互：顶栏纯展示，不注册点击/滑动（避免误触）。

@module koplugin.book.ui.components.topbar
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local TextWidget = require("ui/widget/textwidget")
local datetime = require("datetime")
local NetworkMgr = require("ui/network/manager")
local util = require("util")
local _ = require("gettext")
local Screen = Device.screen

local UI = require("ui.components.bookui")
local Icon = require("ui.components.icon")
local MoonSettings = require("utils.settings")
local SourceRegistry = require("source.registry")

local TopBar = {}

--- 电池分段数（整格点亮，墨水屏可见）
local SEGMENTS = 5

--- 顶栏小图标逻辑尺寸（小于底栏的 24）。
local ICON_SIZE = 14

--- 顶栏小图标边长（像素，电池等自绘图形用）。
---@return number
local function iconSz()
    return UI.sz(ICON_SIZE)
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

--- 电池外形 + 分段填充。pct 0–100；charging 时外壳浅底；低电反色便于墨水屏辨认。
---@param pct number|nil
---@param charging boolean|nil
---@return table
local function batteryGlyph(pct, charging)
    pct = tonumber(pct) or 0
    if pct < 0 then pct = 0 end
    if pct > 100 then pct = 100 end

    local h = iconSz()
    local tip_w = math.max(2, math.floor(h * 0.18 + 0.5))
    local tip_h = math.max(3, math.floor(h * 0.42 + 0.5))
    local body_h = math.max(6, math.floor(h * 0.72 + 0.5))
    local border = math.max(1, UI.line())
    local gap = math.max(1, math.floor(UI.sz(1)))
    local seg_w = math.max(2, math.floor(h * 0.22 + 0.5))
    local inner_pad = math.max(1, border)
    local body_w = border * 2 + inner_pad * 2 + seg_w * SEGMENTS + gap * (SEGMENTS - 1)
    local total_w = body_w + tip_w

    -- 空=0；非空至少 1 格，ceil 均匀铺满 SEGMENTS
    local lit = (pct <= 0) and 0 or math.min(SEGMENTS, math.ceil(pct * SEGMENTS / 100))

    local critical = (not charging) and pct > 0 and pct <= 15
    local on_color = Blitbuffer.COLOR_BLACK
    local off_color = UI.track()
    local body_bg = Blitbuffer.COLOR_WHITE
    if critical then
        -- 低电反色外壳：黑底白格
        on_color = Blitbuffer.COLOR_WHITE
        off_color = Blitbuffer.COLOR_BLACK
        body_bg = Blitbuffer.COLOR_BLACK
    elseif charging then
        body_bg = UI.track()
    end

    -- 色块必须用有尺寸的子控件；空 FrameContainer 在 getSize() 里 self[1] 为 nil 会炸
    local segs = HorizontalGroup:new{ align = "center" }
    local seg_h = math.max(1, body_h - border * 2 - inner_pad * 2)
    for i = 1, SEGMENTS do
        if i > 1 then
            table.insert(segs, HorizontalSpan:new{ width = gap })
        end
        table.insert(segs, LineWidget:new{
            background = (i <= lit) and on_color or off_color,
            dimen = Geom:new{ w = seg_w, h = seg_h },
        })
    end

    local body = FrameContainer:new{
        bordersize = border,
        color = Blitbuffer.COLOR_BLACK,
        padding = inner_pad,
        background = body_bg,
        dimen = Geom:new{
            w = body_w,
            h = body_h,
        },
        segs,
    }

    -- 正极小头：满电/充电实心，低电随外壳反色，其余用分割线色
    local tip = LineWidget:new{
        background = (critical and Blitbuffer.COLOR_WHITE)
            or ((charging or lit >= SEGMENTS) and Blitbuffer.COLOR_BLACK or UI.rule()),
        dimen = Geom:new{ w = tip_w, h = tip_h },
    }

    local shell = HorizontalGroup:new{
        align = "center",
        body,
        CenterContainer:new{
            dimen = Geom:new{ w = tip_w, h = body_h },
            tip,
        },
    }

    return CenterContainer:new{
        dimen = Geom:new{ w = total_w, h = h },
        shell,
    }
end

--- 电池指标：分段图标 +「[+ ]NN%」。
---@param pct number
---@param charging boolean|nil
---@return table
local function batteryMetric(pct, charging)
    local row = HorizontalGroup:new{ align = "center" }
    table.insert(row, batteryGlyph(pct, charging))
    table.insert(row, HorizontalSpan:new{ width = UI.sz(3) })
    local label = string.format("%d%%", pct)
    if charging then
        label = "+" .. label
    end
    table.insert(row, TextWidget:new{
        text = label,
        face = UI.face("xx_smallinfofont", 12),
        fgcolor = Blitbuffer.COLOR_BLACK,
    })
    return row
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

--- 构建一整条顶栏 widget（无缓存；调用方负责挂到 Desktop 并 setDirty）。
---@return table
function TopBar.build()
    local sw = Screen:getWidth()
    local th = UI.topBarH()
    local pad = UI.pagePad()
    local gap_w = UI.sz(10)
    local line_h = UI.line()
    local inner_h = th - line_h
    local inner_w = sw - pad * 2

    -- 左：当前源（过长截断，最多约占内容宽 42%）
    local left = Icon.label{
        name = "source",
        text = sourceName(),
        size = ICON_SIZE,
        font_size = 12,
        gap = UI.sz(4),
        max_width = math.floor(inner_w * 0.42),
    }

    -- 右：监控项；缺能力/读失败则跳过该项（不占位）
    local right = HorizontalGroup:new{ align = "center" }
    local n = 0
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
        n = n + 1
    end

    -- 可用内存（util.calcFreeMem 返回字节；非 Linux 为 nil）
    local mem_avail, mem_total = util.calcFreeMem()
    mem_avail, mem_total = tonumber(mem_avail), tonumber(mem_total)
    if mem_avail and mem_total and mem_total > 0 then
        local mib = math.floor(mem_avail / (1024 * 1024) + 0.5)
        add(metric("memory", string.format("%d MiB", mib)))
    end

    if Device:hasBattery() and Device.powerd then
        local pct = Device.powerd:getCapacity()
        if type(pct) == "number" then
            add(batteryMetric(pct, Device.powerd:isCharging()))
        end
    end

    if Device:hasFrontlight() and Device.powerd and Device.powerd.frontlightIntensity then
        local lvl = Device.powerd:frontlightIntensity()
        if type(lvl) == "number" then
            add(metric("brightness_6", string.format("%d%%", lvl)))
        end
    end

    local wifi_on = NetworkMgr:isWifiOn()
    add(metric(wifi_on and "wifi" or "wifi_off", wifi_on and _("Wi‑Fi") or _("离线")))

    -- 跟随 KOReader 12/24 小时制设置
    local clock = datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock"))
    add(metric("schedule", clock))

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
