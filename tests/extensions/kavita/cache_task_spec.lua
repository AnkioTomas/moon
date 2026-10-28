--[[--
漫画缓存的后台任务：登记 passive 任务、按本批卷轮询、暂停时放行自动休眠、收尾只提示一次。

kamare 仍是执行者，这里只观察 queue_state / status；队列全局共享，所以进度只数本批的卷。

@module tests.extensions.kavita.cache_task_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, inject-field, redundant-parameter

local Assert = require("support.assert")
local Config = require("support.config")
local Kit = require("support.widget_stubs")
Kit.install("paper")

local Themed = require("support.theme_stubs")
Themed.install()

package.preload["ui/network/manager"] = function()
    return { isConnected = function() return true end }
end
package.preload["ui.guard"] = function()
    return { call = function(_label, fn, ...) return fn(...) end }
end
package.preload["utils.log"] = function()
    return { info = function() end, warn = function() end, err = function() end, dbg = function() end }
end

local PLUGIN = Config.root() .. "/extensions/moonsource-kavita.koplugin"

-- 缓存适配层：只提供 cache_task 用到的读接口；写操作不经过这里。
local st = { queue = { state = "idle", entries = {} }, statuses = {}, queue_ok = true }
package.preload["moonsource_kavita.cache"] = function()
    return {
        available = function(cap) return st.queue_ok and cap == "queue" end,
        queueState = function() return st.queue end,
        status = function(id) return st.statuses[tostring(id)] end,
        isCached = function(status)
            return type(status) == "table" and (status.state == "complete" or status.state == "stale")
        end,
    }
end

local Tasks = require("workers.tasks")
local CacheTask = dofile(PLUGIN .. "/moonsource_kavita/cache_task.lua")

local series = { stable_id = "900", title = "测试系列" }
local entries = {
    { chapterId = 1, title = "第 1 卷" },
    { chapterId = 2, title = "第 2 卷" },
    { chapterId = 3, title = "第 3 卷" },
}

--- 跑一条指定延迟的定时器：<1 是队列的变更拍，>=1 是轮询拍。
---@param match fun(delay: number): boolean
---@return boolean
local function runTimer(match)
    for index, item in ipairs(Kit.scheduled) do
        if match(item.delay) then
            table.remove(Kit.scheduled, index)
            item.fn()
            return true
        end
    end
    return false
end

--- 结清队列的变更拍（pause_auto_suspend 之类）。
local function changes()
    while runTimer(function(delay) return delay < 1 end) do end
end

--- 跑一拍轮询。
local function tick()
    Assert.is_true(runTimer(function(delay) return delay >= 1 end), "排了下一拍轮询")
end

local function reset()
    for _idx, item in ipairs(Tasks.tasks()) do
        local live = Tasks.get(item.key)
        if live then live.cancel() end
    end
    changes()
    st.queue = { state = "idle", entries = {} }
    st.statuses = {}
    st.queue_ok = true
    Themed.made = {}
    Kit.scheduled, Kit.unscheduled = {}, {}
end

-- 没装 / 旧核没有 workers.tasks：返回 nil，调用方退回页内进度框。
do
    local real = package.loaded["workers.tasks"]
    package.loaded["workers.tasks"] = nil
    package.preload["workers.tasks"] = function() error("module not found") end
    Assert.is_nil(CacheTask.track{ series = series, entries = entries })
    package.preload["workers.tasks"] = nil
    package.loaded["workers.tasks"] = real
    reset()
end

-- 缺 queue 能力：没有可轮询的队列，不登记（免得后台任务永远挂着）。
do
    reset()
    st.queue_ok = false
    Assert.is_nil(CacheTask.track{ series = series, entries = entries })
    Assert.len(Tasks.tasks(), 0)
    st.queue_ok = true
end

-- 登记：一条 passive 的 cache 任务，顶栏读到「执行中 1/1」；缓存期间不自动休眠。
do
    reset()
    local handle = CacheTask.track{ series = series, entries = entries }
    Assert.not_nil(handle)
    local list = Tasks.tasks()
    Assert.len(list, 1, "只登记一条")
    Assert.eq(list[1].kind, "cache")
    Assert.eq(list[1].title, "测试系列")
    Assert.eq(list[1].state, "running", "passive 任务立刻启动，不排队")
    changes()
    Assert.is_true(require("pluginshare").pause_auto_suspend, "缓存期间压住自动休眠")
end

-- 进度：只数本批的卷，当前卷名来自 queue.current_chapter_id。
do
    reset()
    CacheTask.track{ series = series, entries = entries }
    st.statuses["1"] = { state = "complete" }
    st.queue = { state = "downloading", entries = { [2] = { state = "downloading" } },
        current_chapter_id = 2 }
    tick()
    local task = Tasks.tasks()[1]
    Assert.eq(task.count, 1, "已落地 1 卷")
    Assert.eq(task.total, 3, "总数是本批卷数")
    Assert.eq(task.text, "第 2 卷", "说明行写当前卷")

    -- 不在本批的卷（别的系列）不计数。
    st.queue.entries[99] = { state = "downloading" }
    tick()
    Assert.eq(Tasks.tasks()[1].count, 1, "别的系列不算进度")
end

-- 全部落地：任务结束、toast 一次、不再排下一拍。
do
    reset()
    CacheTask.track{ series = series, entries = entries }
    for index = 1, 3 do st.statuses[tostring(index)] = { state = "complete" } end
    st.queue = { state = "idle", entries = {} }
    local toasts = #Themed.all("toast")
    tick()
    Assert.len(Tasks.tasks(), 0, "结束后离开未结束列表")
    local finished = Tasks.finished()[1]
    Assert.is_true(finished.ok, "全成算成功")
    Assert.eq(finished.total, 3)
    Assert.eq(finished.count, 3, "收尾补报最终计数（不是上一拍的 2/3）")
    Assert.is_nil(finished.text, "收尾后不再挂着上一卷的名字")
    Assert.eq(#Themed.all("toast"), toasts + 1, "只 toast 一次")
    Assert.eq(Themed.last("toast").text, "已缓存 3 卷")
    Assert.is_false(runTimer(function(delay) return delay >= 1 end), "收尾后不再轮询")
    changes()
    Assert.is_false(require("pluginshare").pause_auto_suspend, "结束放行自动休眠")
end

-- 部分失败：失败项是终态（kamare 留在队列里等重试），收尾报成功 / 失败数。
do
    reset()
    CacheTask.track{ series = series, entries = entries }
    st.statuses["1"] = { state = "complete" }
    st.statuses["2"] = { state = "complete" }
    st.queue = { state = "idle", entries = { [3] = { state = "failed", last_error = "http 403" } } }
    tick()
    local finished = Tasks.finished()[1]
    Assert.is_false(finished.ok)
    Assert.eq(finished.total, 3)
    Assert.eq(finished.count, 2, "失败的那卷不算成功")
    Assert.eq(Themed.last("toast").text, "2 卷成功，1 卷失败")
end

-- 静音：页面自己的进度框负责提示时不出 toast。
do
    reset()
    local handle = CacheTask.track{ series = series, entries = entries }
    handle.mute(true)
    for index = 1, 3 do st.statuses[tostring(index)] = { state = "complete" } end
    st.queue = { state = "idle", entries = {} }
    local toasts = #Themed.all("toast")
    tick()
    Assert.eq(#Themed.all("toast"), toasts, "静音时不提示")
    Assert.is_true(Tasks.finished()[1].ok, "任务照常收尾")
end

-- 暂停：说明行给暂停原因，放行自动休眠，轮询放慢到 5 秒；恢复后继续。
do
    reset()
    CacheTask.track{ series = series, entries = entries }
    st.statuses["1"] = { state = "complete" }
    st.queue = { state = "paused", pause_reason = "low_space",
        entries = { [2] = { state = "queued" } } }
    changes()
    tick()
    local task = Tasks.tasks()[1]
    Assert.eq(task.state, "running", "暂停只是报状态，不结束任务")
    Assert.eq(task.text, "空间不足，已暂停")
    changes()
    Assert.is_false(require("pluginshare").pause_auto_suspend, "暂停时不再撑着不睡")
    Assert.is_true(runTimer(function(delay) return delay == 5 end), "暂停时 5 秒一拍")

    -- 恢复：下一拍回到下载说明行，重新压住休眠。
    st.queue = { state = "downloading", entries = { [2] = { state = "downloading" } },
        current_chapter_id = 2 }
    tick()
    Assert.eq(Tasks.tasks()[1].text, "第 2 卷")
    changes()
    Assert.is_true(require("pluginshare").pause_auto_suspend, "恢复后继续撑住")
end

-- 队列丢了（kamare 重启 / 队列被清）：连续几拍看不到本批的项就按中断收尾。
do
    reset()
    CacheTask.track{ series = series, entries = entries }
    local toasts = #Themed.all("toast")
    for _idx = 1, 4 do
        tick()
        Assert.len(Tasks.tasks(), 1, "还没到上限，继续等")
    end
    tick()
    Assert.len(Tasks.tasks(), 0, "超时后收尾")
    local finished = Tasks.finished()[1]
    Assert.is_false(finished.ok)
    Assert.eq(#Themed.all("toast"), toasts + 1)
    Assert.eq(Themed.last("toast").text, "缓存已中断")
end

-- 同一部再有卷入队 / 重试：并进同一条任务，失败项清掉终态重新观察。
do
    reset()
    local first = CacheTask.track{ series = series, entries = { entries[1] } }
    Assert.eq(Tasks.tasks()[1].total, 1)
    st.queue = { state = "downloading", entries = { [1] = { state = "downloading" } } }
    tick()
    Assert.eq(Tasks.tasks()[1].total, 1)

    local merged = CacheTask.track{ series = series, entries = { entries[2], entries[3] } }
    Assert.eq(merged, first, "同一部书复用同一条任务")
    Assert.len(Tasks.tasks(), 1, "不新增任务")
    Assert.eq(Tasks.tasks()[1].total, 3, "总数并进去")

    -- 失败项重试：终态清掉，重新计入进度。
    st.statuses["1"] = { state = "complete" }
    st.queue = { state = "downloading", entries = { [2] = { state = "downloading" },
        [3] = { state = "failed" } } }
    tick()
    Assert.eq(Tasks.tasks()[1].count, 1, "失败项不算成功")
    merged.add({ entries[3] })
    st.queue = { state = "downloading", entries = { [2] = { state = "downloading" },
        [3] = { state = "downloading" } } }
    tick()
    Assert.eq(Tasks.tasks()[1].count, 1, "重试的卷回到未完成")
    st.statuses["2"] = { state = "complete" }
    st.statuses["3"] = { state = "complete" }
    st.queue = { state = "idle", entries = {} }
    tick()
    Assert.is_true(Tasks.finished()[1].ok, "重试成功后收尾")
end
