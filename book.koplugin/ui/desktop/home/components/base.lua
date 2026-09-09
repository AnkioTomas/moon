--[[--
首页子组件基类：Lifecycle。书架和日数据在 Home 上，孩子读 self.home。

@module koplugin.book.ui.desktop.home.components.base
--]]

local Lifecycle = require("ui.lifecycle")

---@class BookHomeComponent : Lifecycle
---@field id string
---@field label string
---@field icon string
---@field home BookHome|nil
local Base = setmetatable({}, Lifecycle)
Base.__index = Base

return Base
