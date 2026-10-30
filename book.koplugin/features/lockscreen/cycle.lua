--[[--
锁屏次数：唤醒 +1。未就绪内容的 cache_key 绑它，避免 compose 整树依赖（Device）。

@module koplugin.book.features.lockscreen.cycle
--]]

local M = {
    --- 本进程经历过的锁屏次数（唤醒时 +1）。
    lock_cycles = 0,
}

--- 未就绪时绑锁屏次数：唤醒后键变才会重合成；就绪后返回空串。
---@param pending boolean|nil
---@return string
function M.pending(pending)
    if not pending then return "" end
    return ":" .. tostring(M.lock_cycles)
end

return M
