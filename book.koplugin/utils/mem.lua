--[[--
可用内存与「重书」提醒阈值。

开书 / KFX 转换峰值常到文件体积的数倍。提醒阈值 = clamp(可用内存/4, 8MB, 40MB)；
读不到 MemAvailable 时回退 20MB（与历史 BIG_BOOK_BYTES 一致）。
字体/样式「重书」降级仍用 reader.prefs.BIG_BOOK_BYTES，不跟瞬时可用内存晃。

@module koplugin.book.utils.mem
--]]

local Mem = {}

local MB = 1024 * 1024
local FALLBACK = 20 * MB
local FLOOR = 8 * MB
local CEIL = 40 * MB

--- 当前大致可用字节（KOReader util.calcFreeMem，已留 85% 余量）；非 Linux（读不到 /proc/meminfo）为 nil。
---@return number|nil
function Mem.availableBytes()
    local free = require("util").calcFreeMem()
    return type(free) == "number" and free > 0 and free or nil
end

--- 首次打开 / KFX 转换前的确认阈值（字节）。
---@return number
function Mem.warnThresholdBytes()
    local free = Mem.availableBytes()
    if not free then return FALLBACK end
    local q = math.floor(free / 4)
    if q < FLOOR then return FLOOR end
    if q > CEIL then return CEIL end
    return q
end

--- 文件是否达到提醒阈值。
---@param size number|nil
---@return boolean
function Mem.isHeavy(size)
    return (tonumber(size) or 0) >= Mem.warnThresholdBytes()
end

--- 展示用整数 MB（向上取整到至少 1，避免「0 MB」）。
---@param bytes number|nil
---@return number|nil
function Mem.mb(bytes)
    bytes = tonumber(bytes)
    if not bytes or bytes < 0 then return nil end
    return math.max(1, math.floor(bytes / MB + 0.5))
end

return Mem
