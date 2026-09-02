--[[--
锁屏组合图生命周期：生成、接管和宿主事件。

@module koplugin.book.lockscreen
--]]

local SimpleJob = require("workers/simple_job")
local Compose = require("lockscreen.compose")
local Settings = require("lockscreen.settings")
local MoonSettings = require("utils.settings")

local M = {}
local job

--- 生成并接管锁屏图；非强制刷新不打断现有生成，缓存命中直接复用。
---@param cb fun(ok: boolean, err: any)|nil
---@param force boolean|nil
function M.refresh(cb, force)
    if not Settings.isCompose() then return end
    if job and not force then return end
    local plan = Compose.plan()
    if Compose.cacheValid(plan, force) then
        Settings.applyCover(plan.output_path)
        if cb then cb(true) end
        return
    end

    if job and job.cancel then job.cancel() end
    job = nil
    local generation = Settings.revision()
    local build
    build = Compose.build(plan, function(ok, err, path)
        if job == build then job = nil end
        if not Settings.isCompose() or generation ~= Settings.revision() then return end
        if not ok then
            if cb then cb(false, err) end
            return
        end
        MoonSettings.get().lock_screen_day = Compose.dayKey(plan)
        MoonSettings.save()
        Settings.applyCover(path or plan.output_path)
        if cb then cb(true) end
    end)
    job = build
end

--- 唤醒后补一次刷新（跨天或书籍变化时换图）。
function M.onResume()
   SimpleJob.run(function() M.refresh(nil, false) end)
end

--- 插件启动：先用有效缓存立刻接管，再后台强制重生成一次。
function M.bootstrap()
    if not Settings.isCompose() then return end
    local plan = Compose.plan()
    if Compose.cacheValid(plan) then
        Settings.applyCover(plan.output_path)
    else
        Settings.clearCover()
    end
    SimpleJob.run(function() M.refresh(nil, true) end)
end

return M
