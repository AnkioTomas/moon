--[[--
顶栏剩余内存。唤醒时原地刷新。

@module koplugin.book.ui.components.topbar.memory
--]]

local util = require("util")
local Base = require("ui.components.topbar.base")

local Memory = setmetatable({}, Base)
Memory.__index = Memory
Memory.id = "memory"

function Memory:onResume()
    local text, icon = self:read()
    self:updateMetric(icon, text)
end

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

---@return table|nil
function Memory:build()
    self.widget = nil
    self.rect = nil
    self.widget = Base.metric("memory", self:read())
    return self.widget
end

return Memory
