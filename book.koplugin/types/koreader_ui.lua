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
---@field align "top"|"bottom"|"center"|nil
---@field [integer] Widget
local WidgetContainer = {}

---@generic T : WidgetContainer
---@param o table|nil
---@return T
function WidgetContainer:extend(o) end

---@generic T : WidgetContainer
---@param o table|nil
---@return T
function WidgetContainer:new(o) end

--- 先 free 再移除全部子控件；skip_free 为真时只移除。
---@param skip_free boolean|nil
function WidgetContainer:clear(skip_free) end

--- 依次交给子控件，任一返回 true 即停止。
---@param event table
---@return boolean
function WidgetContainer:propagateEvent(event) end

--- 子控件都不消费时才调用自身的 on<Event>。
---@param event table
---@return boolean|nil
function WidgetContainer:handleEvent(event) end

---@param full boolean|nil
function WidgetContainer:free(full) end

--- ui/widget/container/inputcontainer.lua
---@class InputContainer : WidgetContainer
---@field key_events table _init 保证非空
---@field ges_events table _init 保证非空
---@field covers_fullscreen boolean|nil

--- ui/widget/menu.lua
---@class Menu : InputContainer
local Menu = {}

---@param select_number number|nil
---@param no_recalculate_dimen boolean|nil
function Menu:updateItems(select_number, no_recalculate_dimen) end
