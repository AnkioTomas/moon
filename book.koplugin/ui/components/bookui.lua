--[[--
Book 桌面 UI 缩放 — 字号 / 间距 / 图标统一从这里走。
缩放值存 moon.settings（$DATA/.moon/settings/common.lua 的 ui_scale）

约定：
  UI.sz(n)       间距、控件几何（含 DPI + ui_scale）
  UI.face(...)   文本字号（ui_scale）
  UI.fontSize(n) 交给 Button/Menu 的数字字号
  UI.iconSz()    图标边长
  UI.line()      分割线粗细
  UI.pluginRoot() / UI.iconDir()  插件根路径与 icons/

@module koplugin.book.ui.components.bookui
--]]

local Device = require("device")
local Font = require("ui/font")
local Blitbuffer = require("ffi/blitbuffer")
local MoonSettings = require("moon.settings")
local Screen = Device.screen

local UI = {}

local _plugin_root

--- 插件根目录（…/book.koplugin/），带尾斜杠
function UI.pluginRoot()
    if _plugin_root then
        return _plugin_root
    end
    local info = debug.getinfo(UI.pluginRoot, "S")
    local src = info and info.source
    if src and src:sub(1, 1) == "@" then
        -- …/book.koplugin/ui/components/bookui.lua
        local root = src:sub(2):match("(.*/)ui/components/[^/]+$")
        if root then
            _plugin_root = root
            return _plugin_root
        end
    end
    local searched = package.searchpath and package.searchpath("ui.components.bookui", package.path)
    if type(searched) == "string" then
        local root = searched:match("(.*/)ui/components/[^/]+$")
        if root then
            _plugin_root = root
            return _plugin_root
        end
    end
    _plugin_root = ""
    return _plugin_root
end

function UI.iconDir()
    return UI.pluginRoot() .. "icons/"
end

local DEFAULT_SCALE = 130
local MIN_SCALE = 100
local MAX_SCALE = 180
local STEP = 10

function UI.getScale()
    local s = MoonSettings.get()
    local n = tonumber(s.ui_scale) or DEFAULT_SCALE
    if n < MIN_SCALE then n = MIN_SCALE end
    if n > MAX_SCALE then n = MAX_SCALE end
    return n
end

function UI.setScale(n)
    n = tonumber(n) or DEFAULT_SCALE
    if n < MIN_SCALE then n = MIN_SCALE end
    if n > MAX_SCALE then n = MAX_SCALE end
    n = math.floor((n + STEP / 2) / STEP) * STEP
    local s = MoonSettings.get()
    s.ui_scale = n
    MoonSettings.save(s)
    return n
end

function UI.cycleScale()
    local n = UI.getScale() + STEP
    if n > MAX_SCALE then n = MIN_SCALE end
    return UI.setScale(n)
end

--- 逻辑像素 → 物理像素，再乘 ui_scale
function UI.sz(n)
    return math.max(1, math.floor(Screen:scaleBySize(n) * UI.getScale() / 100 + 0.5))
end

--- 纯数字字号（Font / Button.text_font_size / Menu.items_font_size）
function UI.fontSize(size)
    return math.max(10, math.floor((size or 16) * UI.getScale() / 100 + 0.5))
end

--- Font:getFace 的缩放包装
function UI.face(name, size)
    return Font:getFace(name, UI.fontSize(size))
end

function UI.line()
    return math.max(1, UI.sz(1))
end

function UI.iconSz()
    return UI.sz(24)
end

function UI.muted()
    return Blitbuffer.COLOR_GRAY_3 -- 0x33，深灰接近黑
end

function UI.dim()
    return Blitbuffer.COLOR_GRAY_4 -- 0x44
end

function UI.rule()
    return Blitbuffer.COLOR_GRAY_5 -- 0x55，分割线可见
end

function UI.track()
    return Blitbuffer.COLOR_LIGHT_GRAY -- 0xCC，空轨浅但不飘
end

--- TitleBar 关闭等图标：把目标边长折算成 size_ratio
function UI.titleIconRatio(base_ratio)
    base_ratio = base_ratio or 0.6
    local ok, defaults = pcall(function()
        return G_defaults:readSetting("DGENERIC_ICON_SIZE")
    end)
    local base = (ok and tonumber(defaults)) or 32
    local native = Screen:scaleBySize(base * base_ratio)
    if native < 1 then native = 1 end
    return UI.iconSz() / native * base_ratio
end

function UI.barH()
    -- 图标 + 文字 + 上下空隙，随字号一起长
    return math.max(UI.sz(56), UI.iconSz() + UI.sz(32))
end

--- 各页统一内容边距（首页 / 书架 / 统计 / 设置 / 详情）
function UI.pagePad()
    return UI.sz(16)
end

--- 节与节之间的垂直间距
function UI.sectionGap()
    return UI.sz(18)
end

--- Desktop 顶部系统状态条高度（容纳小图标 + 分段电池）
function UI.topBarH()
    return math.max(UI.sz(32), UI.fontSize(12) + UI.sz(16))
end

function UI.menuFontSize()
    return UI.fontSize(22)
end

function UI.buttonFontSize()
    return UI.fontSize(20)
end

--- 网格封面高度上限：跟屏高走，避免宽屏三列把封面撑到半屏。
function UI.gridCoverMaxH(area_h)
    local screen_h = Screen:getHeight()
    area_h = tonumber(area_h) or screen_h
    -- 约屏高 21%；下限抬高，避免「经常显得太小」
    local max_h = math.max(UI.sz(100), math.min(UI.sz(156), math.floor(screen_h * 0.21)))
    if area_h > 0 and area_h < screen_h then
        local title_extra = UI.sz(26)
        local row_gap = UI.sz(12)
        -- 尽量两行，但不把单本压得过狠：两行预算至少保住 max_h 的 85%
        local two_row = math.floor((area_h - row_gap) / 2 - title_extra)
        if two_row >= UI.sz(80) then
            max_h = math.min(max_h, math.max(two_row, math.floor(max_h * 0.85)))
        end
    end
    return max_h
end

--- 网格尺度：列宽铺满屏幕；封面在格子里保持 2:3。
--- 返回 slot_w, cover_w, cover_h, cols, gap
---   slot_w  — 格子宽（列均分，吃满 avail）
---   cover_* — 真实封面框（始终约 2:3，居中放进格子）
function UI.coverGridMetrics(avail_w, area_h, opts)
    opts = opts or {}
    avail_w = math.max(1, math.floor(tonumber(avail_w) or 1))
    local gap = opts.gap or UI.sz(12)
    local min_cw = opts.min_cw or UI.sz(56)
    local min_cols = opts.min_cols or 2
    local max_cols = opts.max_cols or 5
    local max_h = UI.gridCoverMaxH(area_h)

    local function widthFor(c)
        return math.floor((avail_w - gap * (c - 1)) / c)
    end

    local cols = 3
    if cols < min_cols then cols = min_cols end
    if cols > max_cols then cols = max_cols end

    local slot_w = widthFor(cols)
    if slot_w < min_cw and cols > min_cols then
        cols = min_cols
        slot_w = widthFor(cols)
    end

    -- 列宽对应的 3:2 仍超高 → 加列，尽量让封面能铺满格子
    while math.floor(slot_w * 3 / 2) > max_h and cols < max_cols do
        local next_w = widthFor(cols + 1)
        if next_w < min_cw then
            break
        end
        cols = cols + 1
        slot_w = next_w
    end

    -- 格子里能放下的最大 2:3 封面
    local cover_h = math.min(max_h, math.floor(slot_w * 3 / 2))
    local cover_w = math.max(1, math.floor(cover_h * 2 / 3))
    if cover_w > slot_w then
        cover_w = slot_w
        cover_h = math.floor(cover_w * 3 / 2)
        if cover_h > max_h then
            cover_h = max_h
            cover_w = math.max(1, math.floor(cover_h * 2 / 3))
        end
    end

    slot_w = math.max(1, slot_w)
    cover_w = math.max(1, cover_w)
    cover_h = math.max(1, cover_h)
    return slot_w, cover_w, cover_h, cols, gap
end

--- 最近阅读主角封面最大高度
function UI.coverMaxH()
    local screen_h = Screen:getHeight()
    return math.max(UI.sz(104), math.min(UI.sz(172), math.floor(screen_h * 0.26)))
end

--- 主角封面：超高则压高度并回缩宽度，保持约 2:3
function UI.coverDim(cw)
    cw = math.max(1, math.floor(tonumber(cw) or 1))
    local ch = math.floor(cw * 3 / 2)
    local max_h = UI.coverMaxH()
    if ch > max_h then
        ch = max_h
        cw = math.max(1, math.floor(ch * 2 / 3))
    end
    return cw, ch
end

--- 简易进度条（0–100）。优先 ProgressWidget；否则用 LineWidget，禁止空 FrameContainer。
function UI.progressBar(width, height, percent)
    local Geom = require("ui/geometry")
    local TextWidget = require("ui/widget/textwidget")
    width = math.max(1, math.floor(tonumber(width) or 1))
    height = math.max(1, math.floor(tonumber(height) or UI.sz(8)))
    percent = tonumber(percent) or 0
    if percent < 0 then percent = 0 end
    if percent > 100 then percent = 100 end

    local ok, ProgressWidget = pcall(require, "ui/widget/progresswidget")
    if ok and ProgressWidget then
        local widget = ProgressWidget:new{
            width = width,
            height = height,
            percentage = percent / 100,
        }
        if widget then
            return widget
        end
    end

    local LineWidget = require("ui/widget/linewidget")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local fill_w = math.floor(width * percent / 100 + 0.5)
    if fill_w < 0 then fill_w = 0 end
    if fill_w > width then fill_w = width end
    local empty_w = width - fill_w
    local row = HorizontalGroup:new{}
    if fill_w > 0 then
        table.insert(row, LineWidget:new{
            background = Blitbuffer.COLOR_BLACK,
            dimen = Geom:new{ w = fill_w, h = height },
        })
    end
    if empty_w > 0 then
        table.insert(row, LineWidget:new{
            background = UI.track(),
            dimen = Geom:new{ w = empty_w, h = height },
        })
    end
    if #row == 0 then
        return TextWidget:new{
            text = string.format("%.0f%%", percent),
            face = UI.face("xx_smallinfofont", 12),
            fgcolor = UI.muted(),
        }
    end
    local border = UI.line()
    return FrameContainer:new{
        bordersize = border,
        color = UI.rule(),
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = width + border * 2, h = height + border * 2 },
        row,
    }
end

return UI
