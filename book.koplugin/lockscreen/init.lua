--[[--
锁屏组合图生命周期：生成、接管和宿主事件。

@module koplugin.book.lockscreen
--]]

local Job = require("workers.job")
local Compose = require("lockscreen.compose")
local Settings = require("lockscreen.settings")
local MoonSettings = require("utils.settings")
local Perf = require("utils.perf")
local logger = require("utils.log")

local M = {}
local job
local job_revision

--- 生成并接管锁屏图；非强制刷新不打断配置仍有效的在飞生成，缓存命中直接复用。
--- 在飞任务的配置已过期时它的结果注定被丢弃，必须让位给新请求，否则无人重跑。
---@param cb fun(ok: boolean, err: any)|nil
---@param force boolean|nil
---@param reason string|nil
function M.refresh(cb, force, reason)
    reason = reason or "request"
    if not Settings.isCompose() then
        logger.dbg("book.lockscreen refresh skipped", reason, "mode_disabled")
        return
    end
    if job and not force and job_revision == Settings.revision() then
        logger.dbg("book.lockscreen refresh skipped", reason, "already_running")
        return
    end
    local plan = Compose.plan()
    if Compose.cacheValid(plan, force) then
        Settings.applyCover(plan.output_path)
        logger.dbg("book.lockscreen refresh skipped", reason, "cache_hit",
            plan.asset.id, plan.component.id, plan.output_path)
        if cb then cb(true) end
        return
    end

    if job and job.cancel then
        logger.dbg("book.lockscreen refresh cancel", reason, "superseded")
        job.cancel()
    end
    job = nil
    local started_at = Perf.now()
    logger.dbg("book.lockscreen refresh start", reason,
        "force", force == true, "background", plan.asset.id,
        "component", plan.component.id, "position", plan.position,
        plan.wide and "wide" or "narrow")
    local generation = Settings.revision()
    local build
    build = Compose.build(plan, function(ok, err, path)
        if job == build then job = nil end
        if not Settings.isCompose() or generation ~= Settings.revision() then
            logger.dbg("book.lockscreen refresh discarded", reason,
                Perf.elapsedMs(started_at), "ms", "settings_changed")
            return
        end
        if not ok then
            logger.warn("book.lockscreen refresh failed", reason,
                Perf.elapsedMs(started_at), "ms", err)
            if cb then cb(false, err) end
            return
        end
        MoonSettings.get().lock_screen_day = Compose.dayKey(plan)
        MoonSettings.save()
        local output_path = path or plan.output_path
        Settings.applyCover(output_path)
        logger.dbg("book.lockscreen refresh done", reason,
            Perf.elapsedMs(started_at), "ms", output_path)
        if cb then cb(true) end
    end)
    job, job_revision = build, generation
end

--- 唤醒后补一次刷新（跨天或书籍变化时换图）。
function M.onResume()
    Job.run(function() M.refresh(nil, false, "resume") end, {
        name = "lockscreen.resume",
        kind = "instant",
    })
end

--- 插件启动：先用有效缓存立刻接管，再后台强制重生成一次。
function M.onCreate()
    if not Settings.isCompose() then
        logger.dbg("book.lockscreen onCreate skipped", "mode_disabled")
        return
    end
    local plan = Compose.plan()
    if Compose.cacheValid(plan) then
        Settings.applyCover(plan.output_path)
        logger.dbg("book.lockscreen onCreate cache", plan.output_path)
    else
        Settings.clearCover()
        logger.dbg("book.lockscreen onCreate cache", "invalid")
    end
    Job.run(function() M.refresh(nil, true, "onCreate") end, {
        name = "lockscreen.onCreate",
        kind = "instant",
    })
end

--- 休眠前强制刷新锁屏图。
function M.onPause()
    M.refresh(nil, true, "suspend")
end

return M
