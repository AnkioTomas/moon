--[[--
端到端：卷列表里「缓存整部」→ 真实缓存适配层 → 真实后台任务队列 → 顶栏读到的任务 → 收尾提示。

用假的 kamare 模块（真缓存适配层 + 真队列 + 真卷列表 + 真轮询），只把「下载」外包出去，
其余全走产品代码：这是跨仓 E2E 在离线环境里能做到的最大范围（模拟器 / 真机另做手工冒烟）。

@module tests.source.kavita.tasks_e2e_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, inject-field, redundant-parameter

local Assert = require("support.assert")
local Config = require("support.config")
local Kit = require("support.widget_stubs")
Kit.install("paper")
local Themed = require("support.theme_stubs")
Themed.install()
-- 真实的卷列表与二级菜单：Themed 的 list 桩会把 item.widget 丢掉，也就点不了行。
package.preload["ui.themes.widgets.list"] = nil
package.loaded["ui.themes.widgets.list"] = nil

local PLUGIN = Config.root() .. "/book.koplugin/source/kavita"

-- 源配置：真 cache.lua 只读 base_url / api_key；其余键仍走 Kit 的主题设置桩。
local cfg = { base_url = "http://kavita.local", api_key = "key" }
package.preload["utils.settings"] = function()
    return {
        get = function(owner)
            local name = owner:match("[^.]+$")
            if name == "ui" then return Kit.display end
            return Kit.sections[name]
        end,
        getSource = function() return cfg end,
        saveSource = function() end,
    }
end
package.preload["utils.log"] = function()
    return { info = function() end, warn = function() end, err = function() end, dbg = function() end }
end
package.preload["ui/network/manager"] = function()
    return { isConnected = function() return true end }
end
package.preload["ui.guard"] = function()
    return { call = function(_label, fn, ...) return fn(...) end }
end

-- 假 kamare：队列与章状态都在内存里，由用例推进。
local statuses, queue = {}, {}
--- 重置假 kamare 的队列与章状态。
local function resetKamare()
    statuses, queue = {}, {}
    queue = { state = "idle", entries = {} }
end
local kamare = {
    api_version = 1,
    capabilities = {
        status = true, resume_page = true, queue = true, queue_control = true,
        index = true, enqueue = true, delete = true, estimate = true, server = true,
    },
}
function kamare.register_server() return "server-key" end
function kamare.status(_base_url, chapter_id) return statuses[tostring(chapter_id)] end
function kamare.queue_state() return queue end
function kamare.estimate(_base_url, entries)
    return { ok = true, chapters = #entries, bytes = #entries * 1024 * 1024,
        available = 4096 * 1024 * 1024 }
end
function kamare.enqueue(_base_url, entries)
    for _idx, entry in ipairs(entries) do
        queue.entries[tostring(entry.chapterId)] = { chapterId = entry.chapterId, state = "queued" }
    end
    queue.state = "downloading"
    return true, nil, { chapters = #entries }
end
package.loaded["kamarecache"] = kamare

--- kamare 开始下某一卷。
local function startChapter(id)
    queue.entries[tostring(id)] = { chapterId = id, state = "downloading" }
    queue.current_chapter_id = id
    queue.state = "downloading"
end

--- kamare 下完某一卷：章状态变 complete，队列项消失。
local function finishChapter(id)
    statuses[tostring(id)] = { state = "complete", bytes = 1024 * 1024 }
    queue.entries[tostring(id)] = nil
    queue.current_chapter_id = nil
    if next(queue.entries) == nil then queue.state = "idle" end
end

package.preload["source.kavita.cache"] = function()
    return dofile(PLUGIN .. "/cache.lua")
end
package.preload["source.kavita.cache_task"] = function()
    return dofile(PLUGIN .. "/cache_task.lua")
end
package.preload["source.kavita.volume_list"] = function()
    return dofile(PLUGIN .. "/volume_list.lua")
end

local Cache = require("source.kavita.cache")
local Tasks = require("workers.tasks")
local VolumeList = require("source.kavita.volume_list")

local series = { stable_id = "900", title = "测试系列" }
local function entry(id, title, pages_read)
    return { chapterId = id, volumeId = id, seriesId = 900, libraryId = 1, format = 1,
        title = title, pages = 100, pagesRead = pages_read or 0 }
end
local toc = { entry(601, "第 1 卷", 100), entry(602, "第 2 卷", 40), entry(603, "第 3 卷", 0) }

--- Kit 的 unschedule 只记录、不从已排列表里删；真实 UIManager 会删，这里按记录过滤。
---@param item table
---@return boolean
local function alive(item)
    for _idx, fn in ipairs(Kit.unscheduled) do
        if fn == item.fn then return false end
    end
    return true
end

--- 结清队列的变更拍（pause_auto_suspend）。
local function changes()
    while true do
        local fired = false
        for index, item in ipairs(Kit.scheduled) do
            if item.delay < 1 and alive(item) then
                table.remove(Kit.scheduled, index)
                item.fn()
                fired = true
                break
            end
        end
        if not fired then return end
    end
end

--- 跑一拍所有 1 秒以上的定时器（页面轮询 + 后台任务轮询各一拍）。
local function round()
    local now, rest = {}, {}
    for _idx, item in ipairs(Kit.scheduled) do
        if item.delay >= 1 and alive(item) then now[#now + 1] = item else rest[#rest + 1] = item end
    end
    Kit.scheduled = rest
    for _idx, item in ipairs(now) do item.fn() end
end

--- 顶栏「后台任务」的读数（与 desktop/topbar 同一口径：running / 未结束总数）。
local function topbarText()
    local list = Tasks.tasks()
    if #list == 0 then return "空闲" end
    local running = 0
    for _idx, task in ipairs(list) do
        if task.state == "running" then running = running + 1 end
    end
    return running .. "/" .. #list
end

---@param list table
---@param widget table
local function tap(list, widget)
    local size = widget.dimen
    local ges = Kit.tap(size.x + math.floor(size.w / 2), size.y + math.floor(size.h / 2))
    ges.ges = "tap"
    list:handleEvent(require("ui/event"):new("Gesture", ges))
end

--- 打开卷列表并走「缓存整部」（菜单第一项）。第 1 卷已缓存，本批只下 2 卷。
local function openAndCacheAll()
    statuses["601"] = { state = "complete", bytes = 1024 }
    local list = assert(VolumeList.pick(series, toc, function() end))
    list:show()
    list:paintTo(Kit.canvas(), 0, 0)
    list.left_callback()
    local menu = Kit.shown[#Kit.shown]
    menu:paintTo(Kit.canvas(), 0, 0)
    local rows = Kit.taps(menu)
    Assert.is_true(#rows >= 1, "有「缓存整部」")
    tap(menu, rows[1])
    local confirm = Themed.last("confirm")
    Assert.not_nil(confirm, "确认框")
    confirm.ok_callback()
    return list
end

local function cleanup()
    for _idx, item in ipairs(Tasks.tasks()) do
        local live = Tasks.get(item.key)
        if live then live.cancel() end
    end
    changes()
    Kit.scheduled, Kit.unscheduled = {}, {}
    Themed.made = {}
    Cache.reset()
    resetKamare()
end

-- 页面开着：入队 → 顶栏看得到 → 进度跟着 kamare 走 → 页面自己的进度框收尾（只提示一次）。
do
    cleanup()
    local list = openAndCacheAll()

    local tracked = Tasks.tasks()
    Assert.len(tracked, 1, "缓存进了后台任务队列")
    Assert.eq(tracked[1].kind, "cache")
    Assert.eq(tracked[1].title, "测试系列")
    Assert.eq(topbarText(), "1/1", "顶栏读到「1/1」")
    changes()
    Assert.is_true(require("pluginshare").pause_auto_suspend, "缓存期间不自动休眠")

    startChapter(602)
    round()
    Assert.eq(Tasks.tasks()[1].text, "第 2 卷", "任务说明行跟 kamare 的当前卷")
    Assert.eq(Tasks.tasks()[1].total, 2, "只数本批（601 已缓存）")

    finishChapter(602)
    startChapter(603)
    round()
    Assert.eq(Tasks.tasks()[1].count, 1, "下完一卷进度 +1")

    finishChapter(603)
    round()
    Assert.len(Tasks.tasks(), 0, "全部落地后离开队列")
    Assert.eq(topbarText(), "空闲")
    changes()
    Assert.is_false(require("pluginshare").pause_auto_suspend, "结束放行自动休眠")
    local toasts = Themed.all("toast")
    Assert.eq(#toasts, 1, "页面进度框收尾，只提示一次")
    Assert.eq(toasts[1].text, "已缓存 2 卷")
    list:close()
end

-- 页面提前关掉：后台任务继续跑，完成时由任务提示（不再有页面轮询）。
do
    cleanup()
    local list = openAndCacheAll()
    startChapter(602)
    round()
    list:close()
    Assert.is_true(#Kit.unscheduled > 0, "关页撤掉页面轮询")

    finishChapter(602)
    startChapter(603)
    round()
    Assert.eq(Tasks.tasks()[1].count, 1, "关页后任务仍在推进")

    finishChapter(603)
    round()
    Assert.len(Tasks.tasks(), 0)
    local toasts = Themed.all("toast")
    Assert.eq(#toasts, 1, "关页后由任务报完成")
    Assert.eq(toasts[1].text, "已缓存 2 卷")
    Assert.eq(topbarText(), "空闲")
end

-- 队列因空间不足暂停：任务留在列表里、报暂停原因、不再压制自动休眠；恢复后继续。
do
    cleanup()
    local list = openAndCacheAll()
    startChapter(602)
    round()
    queue.state = "paused"
    queue.pause_reason = "low_space"
    round()
    Assert.eq(Tasks.tasks()[1].text, "空间不足，已暂停")
    changes()
    Assert.is_false(require("pluginshare").pause_auto_suspend, "暂停时允许自动休眠")

    queue.state = "downloading"
    queue.pause_reason = nil
    round()
    changes()
    Assert.is_true(require("pluginshare").pause_auto_suspend, "恢复后继续撑住")
    finishChapter(602)
    finishChapter(603)
    round()
    Assert.len(Tasks.tasks(), 0, "恢复后照常收尾")
    list:close()
end
