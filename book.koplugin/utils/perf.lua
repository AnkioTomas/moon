--[[--
毫秒级性能计时：LuaSocket 的毫秒墙钟。

@module koplugin.book.utils.perf
--]]

local Perf = {}

---@return number
function Perf.now()
    return require("socket").gettime() * 1000
end

---@param started_at number
---@return number
function Perf.elapsedMs(started_at)
    return math.max(0, math.floor(Perf.now() - started_at + 0.5))
end

return Perf
