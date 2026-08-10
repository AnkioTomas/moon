--[[--
Book 桌面 UI 缩放 — 字号 / 间距统一从这里走。
设置键：book_plugin_v2.ui_scale（百分比，默认 130）

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

--- Font:getFace 的缩放包装
function UI.face(name, size)
    local scaled = math.max(10, math.floor((size or 16) * UI.getScale() / 100 + 0.5))
    return Font:getFace(name, scaled)
end

function UI.barH()
    return UI.sz(56)
end

function UI.iconSz()
    return UI.sz(24)
end

function UI.menuFontSize()
    return math.max(16, math.floor(22 * UI.getScale() / 100 + 0.5))
end

--- 简易进度条（0–100）
function UI.progressBar(width, height, percent)
    local Blitbuffer = require("ffi/blitbuffer")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local Geom = require("ui/geometry")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    percent = tonumber(percent) or 0
    if percent < 0 then percent = 0 end
    if percent > 100 then percent = 100 end
    local h = height or UI.sz(8)
    local fill_w = math.floor(width * percent / 100 + 0.5)
    local empty_w = math.max(0, width - fill_w)
    local row = HorizontalGroup:new{}
    if fill_w > 0 then
        table.insert(row, FrameContainer:new{
            bordersize = 0,
            padding = 0,
            margin = 0,
            background = Blitbuffer.COLOR_BLACK,
            dimen = Geom:new{ w = fill_w, h = h },
        })
    end
    if empty_w > 0 then
        table.insert(row, FrameContainer:new{
            bordersize = 0,
            padding = 0,
            margin = 0,
            background = Blitbuffer.gray(0.85),
            dimen = Geom:new{ w = empty_w, h = h },
        })
    end
    return FrameContainer:new{
        bordersize = 1,
        color = Blitbuffer.gray(0.55),
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = width, h = h + 2 },
        row,
    }
end

UI.DEFAULT_SCALE = DEFAULT_SCALE
UI.MIN_SCALE = MIN_SCALE
UI.MAX_SCALE = MAX_SCALE
UI.STEP = STEP

return UI
