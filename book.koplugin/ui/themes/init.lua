--[[--
界面主题：纸本 paper / 高对比 bold / 柔和 soft 三套令牌，组件在 ui/themes/widgets。

令牌是纯数据，不依赖 KOReader：
  颜色  8 位灰度（0x00 黑 … 0xFF 白），组件里经 Blitbuffer.Color8 变成颜色
  尺寸  逻辑像素，组件里经 Theme.px 走 UI.sz（含 DPI 与 ui_scale）
  字号  逻辑字号，直接交给 UI.face

三套主题的键集合完全一致（tests/ui/themes 校验），组件只读键、不判断主题 id。
当前主题读 display.ui_theme，未设或写错回落 paper。

@module koplugin.book.ui.themes
--]]

local MoonSettings = require("utils.settings")
local UI = require("ui.components.bookui")

---@class BookTheme
local Theme = {}

--- 主题 id，顺序即展示顺序。
Theme.ids = { "paper", "bold", "soft" }

local DEFAULT = "paper"
local known = {}
for _, id in ipairs(Theme.ids) do known[id] = true end

--- 取指定主题的令牌表。
---@param id string
---@return table
function Theme.get(id)
    assert(known[id], "unknown ui theme: " .. tostring(id))
    return (require("ui.themes." .. id))
end

--- 当前主题令牌表。
---@return table
function Theme.current()
    local id = MoonSettings.get("display").ui_theme
    return Theme.get(known[id] and id or DEFAULT)
end

--- 逻辑像素 → 物理像素；0 保持 0（UI.sz 最小返回 1，边框、阴影的「无」会被画成 1px）。
---@param n number
---@return number
function Theme.px(n)
    return n > 0 and UI.sz(n) or 0
end

return Theme
