--[[--
后台任务列表弹窗：随队列原地刷新、尺寸变化才刷下层、只能取消可重跑的任务、关窗注销订阅。
前台跟随：进度随队列刷新、任务结束自动关窗、可重跑才有取消、转后台后等网络提示一次。
start：同 key 执行中拒绝提示、排队中替换并关掉旧窗。

@module tests.workers.ui.task_dialog_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")
local Themed = require("support.theme_stubs")
Themed.install()

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(s) return s end end
package.preload["ffi/util"] = function()
    return {
        template = function(s, ...)
            local args = { ... }
            return (s:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
        end,
    }
end
local connected = true
package.preload["ui/network/manager"] = function()
    return { isConnected = function() return connected end }
end

local Rect = {}
Rect.__index = Rect
function Rect:copy() return setmetatable({ x = self.x, y = self.y, w = self.w, h = self.h }, Rect) end
function Rect:combine(o) return setmetatable({ x = 0, y = 0, w = math.max(self.w, o.w), h = self.h + o.h }, Rect) end
function Rect:intersectWith(o)
    return self.x >= o.x and self.x <= o.x + o.w and self.y >= o.y and self.y <= o.y + o.h
end
package.preload["ui/geometry"] = function()
    return { new = function(_, o) return setmetatable(o, Rect) end }
end
package.preload["device"] = function()
    return {
        screen = {
            getSize = function() return setmetatable({ x = 0, y = 0, w = 600, h = 800 }, Rect) end,
            getWidth = function() return 600 end,
            getHeight = function() return 800 end,
            scaleBySize = function(_, v) return v end,
        },
        hasKeys = function() return false end,
        isTouchDevice = function() return true end,
    }
end
package.preload["ui/gesturerange"] = function() return { new = function(_, o) return o end } end

--- 叶子控件：固定高度。
local function leaf(h)
    return function()
        return { new = function(_, o) o.getSize = function() return { w = 10, h = h } end; return o end }
    end
end
package.preload["ui/widget/horizontalspan"] = leaf(0)
package.preload["ui/widget/verticalspan"] = leaf(2)
--- 容器：高度为子控件之和。
local function box()
    return {
        new = function(_, o)
            o.getSize = function(self)
                local h = 0
                for _, child in ipairs(self) do h = h + child:getSize().h end
                return { w = 10, h = h }
            end
            return o
        end,
    }
end
package.preload["ui/widget/verticalgroup"] = box
package.preload["ui.themes.widgets.box"] = box
package.preload["ui.themes.widgets.progress"] = leaf(5)
package.preload["ui.themes.widgets.text"] = function()
    return { line = function(_, text) return { text = text, getSize = function() return { w = 10, h = 10 } end } end }
end
package.preload["ui.themes"] = function()
    return {
        px = function(v) return v end,
        current = function() return { space = { xs = 2, sm = 4, lg = 8 }, dialog = {} } end,
    }
end
require("support.modal_stub").install()

local scheduled, dirty, shown, closed = {}, {}, {}, {}
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_, _, fn) scheduled[#scheduled + 1] = fn end,
        setDirty = function(_, widget, fn) dirty[#dirty + 1] = { widget = widget, fn = fn } end,
        show = function(_, w) shown[#shown + 1] = w end,
        close = function(_, w) closed[#closed + 1] = w end,
    }
end
local function flush()
    local fns = scheduled
    scheduled = {}
    for _, fn in ipairs(fns) do fn() end
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
Tasks.enqueue(spec("a", true))
Tasks.enqueue(spec("b", false))
flush()

local TaskDialog = require("workers.ui.task_dialog")
local dialog = TaskDialog:new{}
dialog:show()
Assert.eq(shown[#shown], dialog)
Assert.eq(#dialog.rows, 2)
Assert.eq(dialog.rows[1].title, "书a")
Assert.is_true(dialog.rows[1].restartable)
Assert.is_false(dialog.rows[2].restartable)
local status = dialog.rows[1].frame[1][3].text
Assert.eq(status, "缓存 · 进行中")

-- 出现进度条：高度变了，连同旧区域刷下层。
dialog.frame.dimen = setmetatable({ x = 0, y = 0, w = 100, h = dialog.frame:getSize().h }, Rect)
runs.a.report("第 3 章", 3, 10)
flush()
Assert.eq(dirty[#dirty].widget, "all")
Assert.eq(dialog.rows[1].frame[1][3].text, "缓存 · 第 3 章 3/10")
Assert.eq(#dialog.rows[1].frame[1], 5, "有 total 才画进度条")

-- 只是进度前进：尺寸不变，只刷弹窗原区域。
dialog.frame.dimen = setmetatable({ x = 0, y = 0, w = 100, h = dialog.frame:getSize().h }, Rect)
runs.a.report("第 4 章", 4, 10)
flush()
Assert.eq(dirty[#dirty].widget, dialog)
local mode = dirty[#dirty].fn()
Assert.eq(mode, "fast")

-- 点不可重跑的任务行：不询问。
dialog.rows[1].frame.dimen = setmetatable({ x = 0, y = 0, w = 100, h = 30 }, Rect)
dialog.rows[2].frame.dimen = setmetatable({ x = 0, y = 40, w = 100, h = 30 }, Rect)
local confirms = #Themed.all("confirm")
Assert.is_true(dialog:onTapModal(nil, { pos = setmetatable({ x = 5, y = 50, w = 0, h = 0 }, Rect) }))
Assert.eq(#Themed.all("confirm"), confirms)
Assert.eq(#closed, 0)

-- 点可重跑的任务行：确认后取消任务，弹窗随队列刷新。
Assert.is_true(dialog:onTapModal(nil, { pos = setmetatable({ x = 5, y = 5, w = 0, h = 0 }, Rect) }))
local confirm = Themed.last("confirm")
Assert.is_true(confirm.shown)
Assert.eq(confirm.text, "取消任务「书a」？")
confirm.ok_callback()
Assert.is_true(runs.a.cancelled)
Assert.is_nil(Tasks.get("a"))
flush()
Assert.eq(#dialog.rows, 1)

-- 点空白收起；关窗注销订阅，之后队列变化不再重建。
Assert.is_true(dialog:onTapModal(nil, { pos = setmetatable({ x = 500, y = 700, w = 0, h = 0 }, Rect) }))
Assert.eq(closed[#closed], dialog)
dialog:onCloseWidget()
Assert.is_nil(dialog.watch)
local frame = dialog.frame
runs.b.done({ ok = true })
flush()
Assert.eq(dialog.frame, frame)

-- 空队列：显示占位文案。
local empty = TaskDialog:new{}
Assert.eq(#empty.rows, 0)
Assert.eq(empty.frame[1][4].text, "当前没有后台任务")
empty:onCloseWidget()

-- 共用文案：download 按字节，其余按条数；brief 省掉步骤文案。
Assert.eq(TaskDialog.label("sync"), "同步书架")
local snap = { kind = "download", state = "running", count = 1048576, total = 4 * 1048576, attempt = 1 }
Assert.eq(TaskDialog.status(snap), "1.0 / 4.0 MB")
snap.total = 0
Assert.eq(TaskDialog.status(snap), "1.0 MB")
snap = { kind = "sync", state = "running", text = "正在上传 a.epub", count = 1, total = 3, attempt = 1 }
Assert.eq(TaskDialog.status(snap), "正在上传 a.epub 1/3")
Assert.eq(TaskDialog.status(snap, true), "1/3")
snap.state = "retry_wait"
Assert.eq(TaskDialog.status(snap), "第 1 次失败，稍后重试")
Assert.eq(TaskDialog.status(snap, true), "稍后重试")
snap.state = "queued"
Assert.eq(TaskDialog.status(snap), "排队中")

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
