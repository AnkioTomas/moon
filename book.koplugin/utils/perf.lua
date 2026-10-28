--[[--
毫秒级性能计时：LuaSocket 的毫秒墙钟。

  - 单点：`Perf.slow(label, started_at)` 自 started_at 起 ≥100ms 记 info。
  - 分段：`local t = Perf.begin("reader.ready")` → 每步 `t:lap("identity")` → 末尾 `t:finish(3000, extra…)`，
    总耗时 ≥ 阈值按 warn 落盘（用户导出的日志能直接看出卡在哪一步），否则 dbg；
    一行格式 `book.perf <label> <总ms> ms <extra…> identity=12 snapshot=340 …`。
    UI 线程里同步跑、可能拖到秒级的入口（ReaderReady、切章、关书、桌面构建、目录构建）都应该带一个。

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

---@class PerfSpan
---@field label string
---@field started_at number
---@field lap_at number
---@field laps string[]
local Span = {}
Span.__index = Span

--- 开始一段分段计时。
---@param label string 日志里的名字，如 "reader.ready"
---@return PerfSpan
function Perf.begin(label)
    local now = Perf.now()
    return setmetatable({ label = label, started_at = now, lap_at = now, laps = {} }, Span)
end

--- 记一步：name=自上一步起的毫秒数。
---@param name string
---@return PerfSpan self
function Span:lap(name)
    local now = Perf.now()
    self.laps[#self.laps + 1] = name .. "=" .. math.max(0, math.floor(now - self.lap_at + 0.5))
    self.lap_at = now
    return self
end

--- 结束：总耗时 ≥ slow_ms 记 warn，否则 dbg；extra 原样跟在耗时后面（源 id、模式等）。
---@param slow_ms number
---@param ... any
---@return number total 总毫秒数
function Span:finish(slow_ms, ...)
    local total = Perf.elapsedMs(self.started_at)
    local Log = require("utils.log")
    local report = total >= slow_ms and Log.warn or Log.dbg
    local n = select("#", ...) + 4
    local args = { "book.perf " .. self.label, total, "ms", ... }
    args[n] = table.concat(self.laps, " ")
    report(unpack(args, 1, n))
    return total
end

return Perf
