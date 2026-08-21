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
---@field extend fun(self: WidgetContainer, o: table|nil): WidgetContainer
---@field new fun(self: WidgetContainer, o: table|nil): WidgetContainer
