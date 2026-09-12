--[[--
顶栏剩余内存。Resume 起每 120 秒刷新。

@module koplugin.book.ui.components.topbar.memory
--]]

local util = require("util")
local Base = require("ui.components.topbar.base")

---@class BookTopBarMemory : BookTopBarItem
local Memory = setmetatable({}, Base)
Memory.__index = Memory
Memory.id = "memory"
Memory.interval = 120

--- 读取系统可用内存；设置隐藏或数据不可用时返回 nil。
---@return string|nil
function Memory:read()
    if not Base.visible("memory") then
        return nil
    end
    local mem_avail = util.calcFreeMem()
    if not mem_avail then
        return nil
    end
    return util.getFriendlySize(mem_avail)
end

--- 构建系统可用内存对应的指标控件；隐藏时返回零尺寸占位 Widget。
---@return table|nil
function Memory:createWidget()
    self.metric_widget = nil
    self.rect = nil
    self.metric_widget = Base.metric("memory", self:read())
    return self.metric_widget or require("ui/widget/widget"):new{ dimen = require("ui/geometry"):new{ w = 0, h = 0 } }
end

return Memory
