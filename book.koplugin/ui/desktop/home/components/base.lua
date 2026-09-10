--[[--
首页子组件基类：Lifecycle。数据各自读 catalog / online；home 只是父拼装器。

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
