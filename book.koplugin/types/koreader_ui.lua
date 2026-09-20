--- KOReader UI 基类桩，仅供 LuaLS / EmmyLua。
--- koreader/frontend 源码无 ---@class，且禁止改 koreader/；
--- 本文件已在 .luarc.json workspace.library 的 book.koplugin/types 下。

---@meta

---@class Widget
local Widget = {}

---@generic T : Widget
---@param o table|nil
---@return T
function Widget:extend(o) end

---@generic T : Widget
---@param o table|nil
---@return T
function Widget:new(o) end

function Widget:free() end

---@param bb BlitBuffer
---@param x number
---@param y number
function Widget:paintTo(bb, x, y) end

---@return table
function Widget:getSize() end

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

--- ui/widget/menu.lua
---@class Menu : InputContainer
local Menu = {}

---@param select_number number|nil
---@param no_recalculate_dimen boolean|nil
function Menu:updateItems(select_number, no_recalculate_dimen) end

--- ffi/archiver Writer（copymanga CBZ 等）
---@class ArchiverWriter
local ArchiverWriter = {}

function ArchiverWriter:close() end
