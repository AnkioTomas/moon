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

--- 自 started_at 起耗时超过 100ms 才记日志（启动路径各步用，定位慢步骤）。
---@param label string
---@param started_at number
function Perf.slow(label, started_at)
    local ms = Perf.elapsedMs(started_at)
    if ms >= 100 then require("utils.log").info("book.perf slow", label, ms, "ms") end
end

return Perf
