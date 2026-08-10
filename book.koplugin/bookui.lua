--[[--
Book 桌面 UI 缩放 — 字号 / 间距统一从这里走。
设置键：book_plugin.ui_scale（百分比，默认 130）

@module koplugin.book.bookui
--]]

local Device = require("device")
local Font = require("ui/font")
local Screen = Device.screen

local UI = {}

local DEFAULT_SCALE = 130
local MIN_SCALE = 100
local MAX_SCALE = 180
local STEP = 10

function UI.getScale()
    local s = G_reader_settings:readSetting("book_plugin") or {}
    local n = tonumber(s.ui_scale) or DEFAULT_SCALE
    if n < MIN_SCALE then n = MIN_SCALE end
    if n > MAX_SCALE then n = MAX_SCALE end
    return n
end

function UI.setScale(n)
    n = tonumber(n) or DEFAULT_SCALE
    if n < MIN_SCALE then n = MIN_SCALE end
    if n > MAX_SCALE then n = MAX_SCALE end
    -- 对齐步进
    n = math.floor((n + STEP / 2) / STEP) * STEP
    local s = G_reader_settings:readSetting("book_plugin") or {}
    s.ui_scale = n
    G_reader_settings:saveSetting("book_plugin", s)
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
    -- KOReader Menu 默认大约 22；按比例放大
    return math.max(16, math.floor(22 * UI.getScale() / 100 + 0.5))
end

UI.DEFAULT_SCALE = DEFAULT_SCALE
UI.MIN_SCALE = MIN_SCALE
UI.MAX_SCALE = MAX_SCALE
UI.STEP = STEP

return UI
