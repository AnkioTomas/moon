--- KOReader UI 基类桩，仅供 LuaLS / EmmyLua。
--- koreader/frontend 源码无 ---@class，且禁止改 koreader/；
--- 本文件已在 .luarc.json workspace.library 的 book.koplugin/types 下。

---@meta

---@class Widget

--- ui/widget/container/widgetcontainer.lua
---@class WidgetContainer : Widget
---@field name string|nil
---@field ui table|nil
---@field dimen table|nil
local WidgetContainer = {}

---@generic T : WidgetContainer
---@param o table|nil
---@return T
function WidgetContainer:extend(o) end

---@generic T : WidgetContainer
---@param o table|nil
---@return T
function WidgetContainer:new(o) end

--- ui/widget/container/inputcontainer.lua
---@class InputContainer : WidgetContainer
---@field ges_events table|nil
---@field covers_fullscreen boolean|nil
