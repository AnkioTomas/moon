--[[--
锁屏次数：唤醒 +1。避免 compose 整树依赖（Device）。

两种绑法：
- pending：每次锁屏键都变（文字海报 / 一言轮换）。
- retry：未就绪内容每 N 次锁屏才换一次键，避免每次唤醒整屏重合成。

@module koplugin.book.features.lockscreen.cycle
--]]

local M = {
    --- 本进程经历过的锁屏次数（唤醒时 +1）。
    lock_cycles = 0,
}

--- 未就绪重试默认间隔（锁屏次数）。
M.RETRY_EVERY = 5

--- 每次锁屏都变：轮换类背景用。
---@param pending boolean|nil
---@return string
function M.pending(pending)
    if not pending then return "" end
    return ":" .. tostring(M.lock_cycles)
end

--- 未就绪重试：每 `every` 次锁屏才进下一桶（默认 RETRY_EVERY）；就绪返回空串。
---@param pending boolean|nil
---@param every number|nil
---@return string
function M.retry(pending, every)
    if not pending then return "" end
    every = tonumber(every) or M.RETRY_EVERY
    if every < 1 then every = 1 end
    return ":" .. tostring(math.floor(M.lock_cycles / every))
end

return M
