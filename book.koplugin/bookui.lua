--[[--
Book 桌面 UI 缩放 — 字号 / 间距 / 图标统一从这里走。
设置键：book_plugin_v2.ui_scale（百分比，默认 130）

约定：
  UI.sz(n)       间距、控件几何（含 DPI + ui_scale）
  UI.face(...)   文本字号（ui_scale）
  UI.fontSize(n) 交给 Button/Menu 的数字字号
  UI.iconSz()    图标边长
  UI.line()      分割线粗细

@module koplugin.book.bookui
--]]

local Device = require("device")
local Font = require("ui/font")
local Screen = Device.screen

local UI = {}

local SETTINGS_KEY = "book_plugin_v2"
local DEFAULT_SCALE = 130
local MIN_SCALE = 100
local MAX_SCALE = 180
local STEP = 10

function UI.settingsKey()
    return SETTINGS_KEY
end

function UI.getScale()
    local s = G_reader_settings:readSetting(SETTINGS_KEY) or {}
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
    local s = G_reader_settings:readSetting(SETTINGS_KEY) or {}
    s.ui_scale = n
    G_reader_settings:saveSetting(SETTINGS_KEY, s)
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

function UI.menuFontSize()
    return UI.fontSize(22)
end

function UI.buttonFontSize()
    return UI.fontSize(20)
end

--- 简易进度条（0–100）。优先 ProgressWidget；否则用 LineWidget，禁止空 FrameContainer。
function UI.progressBar(width, height, percent)
    local Blitbuffer = require("ffi/blitbuffer")
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
            background = Blitbuffer.gray(0.85),
            dimen = Geom:new{ w = empty_w, h = height },
        })
    end
    if #row == 0 then
        return TextWidget:new{
            text = string.format("%.0f%%", percent),
            face = UI.face("xx_smallinfofont", 12),
            fgcolor = Blitbuffer.gray(0.4),
        }
    end
    local border = UI.line()
    return FrameContainer:new{
        bordersize = border,
        color = Blitbuffer.gray(0.55),
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = width + border * 2, h = height + border * 2 },
        row,
    }
end

UI.DEFAULT_SCALE = DEFAULT_SCALE
UI.MIN_SCALE = MIN_SCALE
UI.MAX_SCALE = MAX_SCALE
UI.STEP = STEP

return UI
