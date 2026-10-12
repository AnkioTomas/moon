--[[--
锁屏组合图生命周期：生成、接管和宿主事件。

KOReader 先 Screensaver:setup/show 再广播 Suspend，所以锁屏图在 setup 读设置之前生成；
内容没变时缓存命中零开销，变了就当场重画，锁屏显示的永远是此刻的状态。

@module koplugin.book.features.lockscreen
--]]

local Compose = require("features.lockscreen.compose")
local Settings = require("features.lockscreen.settings")
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
        MoonSettings.get("features.lockscreen").lock_screen_day = Compose.dayKey(plan)
        MoonSettings.save("features.lockscreen")
        local output_path = path or plan.output_path
        Settings.applyCover(output_path)
        logger.dbg("book.lockscreen refresh done", reason,
            Perf.elapsedMs(started_at), "ms", output_path)
        if cb then cb(true) end
    end)
    job, job_revision = build, generation
end

--- 是否有生成任务在飞；设置页预览据此区分「生成中」和「未生成」。
---@return boolean
function M.running()
    return job ~= nil
end

--- 锁屏前同步刷新：Screensaver:setup 读 screensaver_document_cover 之前图必须已经就位。
--- 带 event 的调用是关机 / 重启画面，不是锁屏。在线资源未就绪时异步生成，本次沿用旧图。
local function hookScreensaver()
    local Screensaver = require("ui/screensaver")
    if Screensaver._book_lockscreen_hooked then return end
    Screensaver._book_lockscreen_hooked = true
    local native_setup = Screensaver.setup
    Screensaver.setup = function(self, event, ...)
        if event == nil then
            require("ui.guard").call("lockscreen.suspend", M.refresh, nil, false, "suspend")
        end
        return native_setup(self, event, ...)
    end
end

--- 插件启动：缓存失效时先撤下旧图（别让上次的配置冒充），下一帧补生成。
function M.onCreate()
    hookScreensaver()
    if not Settings.isCompose() then
        logger.dbg("book.lockscreen onCreate skipped", "mode_disabled")
        return
    end
    if not Compose.cacheValid(Compose.plan()) then
        Settings.clearCover()
    end
    require("ui/uimanager"):nextTick(function() M.refresh(nil, false, "onCreate") end)
end

--- 网络恢复：必应 / 摸鱼日报 / 一言可能刚就绪；内容没变就是缓存命中。
function M.onNetworkConnected()
    M.refresh(nil, false, "network_connected")
end

return M
