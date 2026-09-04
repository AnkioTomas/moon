--[[--
毫秒级性能计时。

运行在 KOReader 时使用 LuaSocket 的毫秒墙钟；不可用时退回 os.clock。
模块顶层不加载原生依赖，源模块可安全 require。

@module koplugin.book.utils.perf
--]]

local Perf = {}
local clock

local function getClock()
    if clock == false then return nil end
    if clock == nil then
        local ok, socket = pcall(require, "socket")
        clock = ok and type(socket.gettime) == "function" and socket.gettime or false
    end
    return clock or nil
end

---@return number
function Perf.now()
    local gettime = getClock()
    if gettime then return gettime() * 1000 end
    return os.clock() * 1000
end

---@param started_at number
---@return number
function Perf.elapsedMs(started_at)
    return math.max(0, math.floor(Perf.now() - started_at + 0.5))
end

return Perf
