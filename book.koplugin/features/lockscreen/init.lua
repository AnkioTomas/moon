--[[--
锁屏组合图生命周期：生成、接管和宿主事件。

KOReader 先 Screensaver:setup/show 再广播 Suspend。电源键路径上绝不同步解码/写 PNG：
缓存命中或已有旧 compose.png 只接管路径；重建留给桌面回到前台 / 设置变更 / 联网后的异步刷新。
低端 Kindle 上同步整屏合成会卡死数秒。

@module koplugin.book.features.lockscreen
--]]

local lfs = require("libs/libkoreader-lfs")
local Compose = require("features.lockscreen.compose")
local Settings = require("features.lockscreen.settings")
local MoonSettings = require("utils.settings")
local Perf = require("utils.perf")
local logger = require("utils.log")

local M = {}
local job
local job_revision
local activated_hooked
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
        Settings.applyCover(plan.output_path, MoonSettings.get("features.lockscreen").lock_screen_transparent)
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
    build = Compose.build(plan, function(ok, err, transparent)
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
        local c = MoonSettings.get("features.lockscreen")
        c.lock_screen_day = Compose.dayKey(plan)
        c.lock_screen_transparent = transparent or nil
        MoonSettings.save("features.lockscreen")
        Settings.applyCover(plan.output_path, transparent)
        logger.dbg("book.lockscreen refresh done", reason,
            Perf.elapsedMs(started_at), "ms", plan.output_path)
        if cb then cb(true) end
    end)
    job, job_revision = build, generation
end

--- 是否有生成任务在飞；设置页预览据此区分「生成中」和「未生成」。
---@return boolean
function M.running()
    return job ~= nil
end

--- 休眠前只接管路径，绝不 Compose.build。命中缓存用新键；miss 时有旧图就顶上（过期也行）。
local function prepareSuspend()
    if not Settings.isCompose() then
        logger.dbg("book.lockscreen suspend skipped", "mode_disabled")
        return
    end
    local plan = Compose.plan()
    local transparent = MoonSettings.get("features.lockscreen").lock_screen_transparent
    if Compose.cacheValid(plan) then
        Settings.applyCover(plan.output_path, transparent)
        logger.dbg("book.lockscreen suspend", "cache_hit", plan.output_path)
        return
    end
    if (lfs.attributes(plan.output_path, "size") or 0) > 0 then
        Settings.applyCover(plan.output_path, transparent)
        logger.dbg("book.lockscreen suspend", "stale_cover", plan.output_path)
        return
    end
    logger.dbg("book.lockscreen suspend", "no_cover")
end

--- Screensaver:setup 读 screensaver_document_cover 之前只做路径接管。
--- 带 event 的调用是关机 / 重启画面，不是锁屏。
local function hookScreensaver()
    local Screensaver = require("ui/screensaver")
    if Screensaver._book_lockscreen_hooked then return end
    Screensaver._book_lockscreen_hooked = true
    local native_setup = Screensaver.setup
    Screensaver.setup = function(self, event, ...)
        if event == nil then
            require("ui.guard").call("lockscreen.suspend", prepareSuspend)
        end
        return native_setup(self, event, ...)
    end
end

--- 缓存失效时异步重建（桌面回到前台 / 启动 / 联网）。不进电源键路径。
local function refreshIfStale(reason)
    if not Settings.isCompose() then return end
    local plan = Compose.plan()
    if Compose.cacheValid(plan) then return end
    M.refresh(nil, false, reason)
end

local function hookDesktopActivated()
    if activated_hooked then return end
    activated_hooked = true
    require("utils.extension").add("desktop.activated", function(_desktop)
        require("ui.guard").call("lockscreen.activated", refreshIfStale, "desktop_activated")
    end)
end

--- 插件启动：缓存失效时先撤下旧图；在线背景未就绪才下一帧下载合成。
--- 本地背景的重建留给 desktop.activated（用户回到桌面时），不进电源键、也不在开书路径卡主线程。
function M.onCreate()
    hookScreensaver()
    hookDesktopActivated()
    Settings.migrate()
    if not Settings.isCompose() then
        logger.dbg("book.lockscreen onCreate skipped", "mode_disabled")
        return
    end
    local plan = Compose.plan()
    if Compose.cacheValid(plan) then return end
    Settings.clearCover()
    if require("features.lockscreen.background").isFresh(plan.asset) then return end
    require("ui/uimanager"):nextTick(function() require("ui.guard").call("lockscreen.create", M.refresh, nil, false, "onCreate") end)
end

--- 网络恢复：必应 / 摸鱼日报 / 一言可能刚就绪；内容没变就是缓存命中。
function M.onNetworkConnected()
    M.refresh(nil, false, "network_connected")
end

return M
