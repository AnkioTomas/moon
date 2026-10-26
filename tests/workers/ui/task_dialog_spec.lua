--[[--
后台任务列表弹窗：主题弹窗，每条任务「任务名 / 进度描述 / 进度条 + 右侧状态」，按屏高分页；
随队列刷新、只能取消可重跑的未结束任务、最近结束的标已完成 / 失败、关窗注销订阅。
前台跟随：进度随队列刷新、任务结束自动关窗、可重跑才有取消、转后台后等网络提示一次。
start：同 key 执行中拒绝提示、排队中替换并关掉旧窗。

@module tests.workers.ui.task_dialog_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")
local Themed = require("support.theme_stubs")
Themed.install()

local connected = true
package.preload["ui/network/manager"] = function()
    return { isConnected = function() return connected end }
end

local function flush()
    local fns = Kit.scheduled
    Kit.scheduled = {}
    for _, item in ipairs(fns) do item.fn() end
end

local Tasks = require("workers.tasks")
local runs = {}
local function spec(key, restartable)
    return {
        key = key, kind = "cache", title = "书" .. key, restartable = restartable,
        run = function(report, done)
            runs[key] = { report = report, done = done }
            return { cancel = function() runs[key].cancelled = true end }
        end,
    }
end
local TaskDialog = require("workers.ui.task_dialog")
local Progress = require("ui.themes.widgets.progress")

local function texts(dialog) return table.concat(Kit.texts(dialog), "|") end
local function bars(dialog)
    return Kit.find(dialog, function(w) return getmetatable(w) == Progress end)
end

-- 空队列且没有历史：标题 + 占位。
local empty = TaskDialog:new{}
Assert.eq(texts(empty), "后台任务|当前没有后台任务")
Assert.len(Kit.taps(empty), 0)
empty:onCloseWidget()

Tasks.enqueue(spec("a", true))
Tasks.enqueue(spec("b", false))
flush()

-- 一条一项：任务名、进度描述（没有时留空行）、进度条，右侧状态；可重跑的才有点击区。
local dialog = TaskDialog:new{}
dialog:show()
Assert.eq(Kit.shown[#Kit.shown], dialog)
Assert.eq(texts(dialog), "后台任务|缓存：书a| |进行中|缓存：书b| |进行中")
Assert.len(bars(dialog), 2)
Assert.eq(bars(dialog)[1].percent, 0)
Assert.eq(bars(dialog)[1].width, dialog.inner, "进度条通栏，延伸到状态下方")
local status_lines = Kit.find(dialog, function(w)
    return w.align == "center" and #w == 3 and Kit.texts(w)[#Kit.texts(w)] == "进行中"
end)
Assert.eq(status_lines[1]:getSize().w, dialog.inner, "左栏定宽，状态贴最右")
Assert.len(Kit.taps(dialog), 1, "不可重跑的不能点")

-- 进度：描述 = 步骤 + 计数，进度条按 count/total。
runs.a.report("第 3 章", 3, 10)
flush()
Assert.eq(texts(dialog), "后台任务|缓存：书a|第 3 章 3/10|进行中|缓存：书b| |进行中")
Assert.eq(bars(dialog)[1].percent, 30)
Assert.eq(Kit.dirty[#Kit.dirty].widget, dialog, "高度没变只刷弹窗")
Assert.eq(Kit.dirty[#Kit.dirty].mode(), "fast", "进度高频变化用快刷，墨水屏不闪")

-- 点可重跑的任务：确认后取消，列表随队列刷新；取消的不进历史；面板变矮重画整屏。
Kit.taps(dialog)[1]:onTapThemeArea()
local confirm = Themed.last("confirm")
Assert.is_true(confirm.shown)
Assert.eq(confirm.text, "取消任务「书a」？")
confirm.ok_callback()
Assert.is_true(runs.a.cancelled)
Assert.is_nil(Tasks.get("a"))
flush()
Assert.eq(texts(dialog), "后台任务|缓存：书b| |进行中")
Assert.eq(Kit.dirty[#Kit.dirty].widget, "all")

-- 完成：标已完成，进度条满，不能点。
runs.b.done({ ok = true })
flush()
Assert.eq(texts(dialog), "后台任务|缓存：书b| |已完成")
Assert.eq(bars(dialog)[1].percent, 100)
Assert.len(Kit.taps(dialog), 0)

-- 关窗注销订阅，之后队列变化不再重建。
dialog:onCloseWidget()
local panel = dialog[1]
Tasks.enqueue(spec("z", false))
flush()
Assert.eq(dialog[1], panel)
runs.z.done({ ok = false })
flush()

-- 分页：未结束在前、结束的在后（新的在前）；按屏高定页长，翻页条 / 左右滑翻页，末页补齐高度。
for i = 1, 20 do Tasks.enqueue(spec("p" .. i, false)) end
flush()
local paged = TaskDialog:new{}
local per = paged.per_page
Assert.is_true(per > 1 and per < 20, "页长按屏高：" .. per)
local first = Kit.texts(paged)
Assert.eq(first[2], "缓存：书p1")
Assert.contains(first, "1 / " .. math.ceil(22 / per))
local height = paged[1]:getSize().h
paged:show()
local function swipe(direction)
    local ges = Kit.tap(1, 1)
    ges.ges, ges.direction = "swipe", direction
    return paged:handleEvent(require("ui/event"):new("Gesture", ges))
end
Assert.is_true(swipe("west"))
Assert.eq(paged.page, 2)
Assert.eq(Kit.texts(paged)[2], "缓存：书p" .. (per + 1))
Assert.is_true(swipe("north"), "未处理的方向不穿透弹窗")
paged:goPage(99)
local pages = math.ceil(22 / per)
Assert.eq(paged.page, pages, "越界夹到末页")
local last = Kit.texts(paged)
Assert.eq(last[#last - 6], "失败", "末页尾部是历史：z 失败在前")
Assert.eq(last[#last - 3], "已完成", "末尾是翻页条：图标 + 页码 + 图标")
Assert.eq(paged[1]:getSize().h, height, "末页补齐，翻页不跳")
paged:onCloseWidget()
for i = 1, 20 do runs["p" .. i].done({ ok = true }) end
flush()

-- 共用文案：download 按字节，其余按条数。
Assert.eq(TaskDialog.label("sync"), "同步书架")
Assert.eq(TaskDialog.label("online"), "在线")
local snap = { kind = "download", state = "running", count = 1048576, total = 4 * 1048576, attempt = 1 }
Assert.eq(TaskDialog.status(snap), "1.0 / 4.0 MB")
snap.total = 0
Assert.eq(TaskDialog.status(snap), "1.0 MB")
snap = { kind = "sync", state = "running", text = "正在上传 a.epub", count = 1, total = 3, attempt = 1 }
Assert.eq(TaskDialog.status(snap), "正在上传 a.epub 1/3")
snap.state = "retry_wait"
Assert.eq(TaskDialog.status(snap), "第 1 次失败，稍后重试")
snap.state = "queued"
Assert.eq(TaskDialog.status(snap), "排队中")
snap = { kind = "cache", state = "finished", ok = true }
Assert.eq(TaskDialog.status(snap), "已完成")
snap.ok = false
Assert.eq(TaskDialog.status(snap), "失败")

-- 前台跟随：弹进度窗并随队列刷新；可重跑的有「取消」；任务完成自动关窗、不再更新。
local f = Tasks.enqueue(spec("f", true))
TaskDialog.follow(f)
local fg = Themed.last("progress_dialog")
Assert.is_true(fg.shown)
Assert.eq(fg.title, "缓存：书f")
Assert.eq(fg.sets[1][1], "进行中")
Assert.not_nil(fg.on_cancel)
runs.f.report(nil, 3, 10)
flush()
Assert.eq(fg.sets[#fg.sets][1], "3/10")
Assert.eq(fg.sets[#fg.sets][2], 30)
runs.f.done({ ok = true })
flush()
Assert.is_true(fg.closed)
local sets = #fg.sets
flush()
Assert.eq(#fg.sets, sets)

-- 已结束的任务不弹窗。
local made = #Themed.made
TaskDialog.follow(f)
Assert.eq(#Themed.made, made)

-- 取消按钮：取消任务。
local c = Tasks.enqueue(spec("c", true))
TaskDialog.follow(c)
local cancel_dialog = Themed.last("progress_dialog")
cancel_dialog:close()
cancel_dialog.on_cancel()
Assert.is_true(runs.c.cancelled)
Assert.is_nil(Tasks.get("c"))

-- 不可重跑：没有取消。
local n = Tasks.enqueue(spec("n", false))
TaskDialog.follow(n)
Assert.is_nil(Themed.last("progress_dialog").on_cancel)
runs.n.done({ ok = true })
flush()
Assert.is_true(Themed.last("progress_dialog").closed)

-- 转后台：只关窗并提示；之后进入等网络提示一次，状态不变不重复提示；任务照常跑完。
local h = Tasks.enqueue(spec("h", true))
TaskDialog.follow(h)
local bg = Themed.last("progress_dialog")
bg:dismiss()
Assert.is_true(bg.closed)
Assert.eq(Themed.last("toast").text, "已转到后台，可在顶栏查看进度")
sets = #bg.sets
connected = false
runs.h.done({ ok = false })
flush()
Assert.eq(h.state, "waiting")
Assert.eq(Themed.last("toast").text, "「书h」等待网络，联网后继续")
local toasts = #Themed.all("toast")
Tasks.onSuspend()
Tasks.onResume()
connected = true
flush()
Assert.eq(#Themed.all("toast"), toasts, "没有新进入等网络就不再提示")
Assert.eq(#bg.sets, sets, "转后台后不再更新弹窗")
runs.h.done({ ok = true })
flush()
Assert.is_nil(Tasks.get("h"))

-- start：入队并前台跟随；同 key 执行中拒绝并提示，不弹新窗。
TaskDialog.start(spec("s", true))
local started = Themed.last("progress_dialog")
Assert.eq(started.title, "缓存：书s")
made = #Themed.made
TaskDialog.start(spec("s", true))
Assert.eq(Themed.last("toast").text, "「书s」正在执行，请稍后再试")
Assert.eq(#Themed.made, made + 1, "只多一个提示")

-- 同 key 尚未执行：旧任务被踢掉，它的跟随窗自动关闭，新任务重新弹窗。
local queued = spec("q", false)
queued.kind = "sync"
TaskDialog.start(queued)
local old = Themed.last("progress_dialog")
Assert.eq(Tasks.get("q").state, "queued")
local replacement = spec("q", false)
replacement.kind = "sync"
TaskDialog.start(replacement)
flush()
Assert.is_true(old.closed)
Assert.is_true(Themed.last("progress_dialog") ~= old)
Assert.eq(Tasks.get("q"), replacement)

-- 队列满：只提示。
TaskDialog.rejected("queue_full", queued)
Assert.eq(Themed.last("toast").text, "任务队列已满")

runs.s.done({ ok = true })
runs.q.done({ ok = true })
flush()
Assert.eq(#Tasks.tasks(), 0)

return true
