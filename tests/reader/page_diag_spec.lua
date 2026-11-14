--[[--
reader.page_diag：默认每次实际翻页写一行 info，慢路径另记，不改返回值与异常。

@module tests.reader.page_diag_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
Stubs.reset()

local clock = { v = 10 }
package.loaded["socket"] = {
    gettime = function()
        return clock.v
    end,
}
package.loaded["utils.perf"] = nil

local logs = {}
package.loaded["utils.log"] = {
    info = function(...)
        local parts = {}
        for i = 1, select("#", ...) do
            parts[i] = tostring(select(i, ...))
        end
        logs[#logs + 1] = table.concat(parts, " ")
    end,
    flush = function()
        logs.flush = (logs.flush or 0) + 1
    end,
}

local check_impl = function(_self, ...)
    return "wait", 7, ...
end
local repaint_impl = function(_self, ...)
    return "painted"
end
local wait_impl = function(_self, ...)
    return nil, ...
end

local UIManager = { _task_queue = {} }
function UIManager:_checkTasks(...)
    return check_impl(self, ...)
end
function UIManager:_repaint(...)
    return repaint_impl(self, ...)
end
package.loaded["ui/uimanager"] = UIManager

local Input = {}
function Input:waitEvent(...)
    return wait_impl(self, ...)
end
package.loaded["device"] = { input = Input }

package.loaded["ui/time"] = {
    now = function()
        return 100
    end,
}

package.loaded["reader.page_diag"] = nil
local Diag = require("reader.page_diag")

local function lines(prefix)
    local out = {}
    for i = 1, #logs do
        if tostring(logs[i]):find(prefix, 1, true) then
            out[#out + 1] = logs[i]
        end
    end
    return out
end

Assert.is_false(Diag.isInstalled())
Assert.is_true(Diag.install())
Assert.is_true(Diag.isInstalled())
Assert.is_true(Diag.isEnabled())

-- 返回值原样保留（含多余返回值）。
local a, b, c = UIManager:_checkTasks("x")
Assert.eq(a, "wait")
Assert.eq(b, 7)
Assert.eq(c, "x")
Assert.eq(UIManager:_repaint(), "painted")
Assert.len(lines("book.diag"), 0, "未超过阈值不写日志")

-- 异常语义：钩子不用 pcall 吞错（改的是被包住的实现，不是钩子本身）。
local prev_check = check_impl
check_impl = function()
    error("task-boom")
end
local ok, err = pcall(function()
    UIManager:_checkTasks()
end)
Assert.is_false(ok)
Assert.is_true(tostring(err):find("task-boom", 1, true) ~= nil)
check_impl = prev_check
Assert.len(lines("book.diag"), 0, "抛错的任务不补写臆造耗时")

-- 慢任务：queued / due 来自真实队列。
UIManager._task_queue = {
    { time = 50, action = function() end },
    { time = 150, action = function() end },
}
check_impl = function()
    clock.v = clock.v + 0.15
end
UIManager:_checkTasks()
local slow_tasks = lines("uimanager.tasks")
Assert.len(slow_tasks, 1)
Assert.is_true(slow_tasks[1]:find("book.diag slow uimanager.tasks 150 ms", 1, true) ~= nil)
Assert.is_true(slow_tasks[1]:find("queued=2", 1, true) ~= nil)
Assert.is_true(slow_tasks[1]:find("due=1", 1, true) ~= nil)

local before = #logs
UIManager._task_queue = { { action = function() end } }
check_impl = function()
    clock.v = clock.v + 0.2
end
UIManager:_checkTasks()
local last = logs[#logs]
Assert.is_true(#logs > before)
Assert.is_true(last:find("queued=1", 1, true) ~= nil)
Assert.is_true(last:find("due=", 1, true) == nil, "不能判定 due 时不写该字段")

-- 慢重绘。
repaint_impl = function(_self, ...)
    clock.v = clock.v + 0.12
    return true, "ok"
end
local r1, r2 = UIManager:_repaint()
Assert.is_true(r1)
Assert.eq(r2, "ok")
Assert.is_true(logs[#logs]:find("book.diag slow uimanager.repaint 120 ms", 1, true) ~= nil)

-- 输入批次：1 个事件只记内存，≥2 才写日志；种类不含正文。
wait_impl = function()
    return {
        { handler = "onGesture", args = { { ges = "tap", pos = { x = 1, y = 2 }, text = "秘密章节" } } },
    }
end
local batch = Input:waitEvent()
Assert.eq(batch[1].args[1].text, "秘密章节", "不改事件内容")
Assert.is_true(logs[#logs]:find("input", 1, true) == nil, "单事件不写 batch 日志")

wait_impl = function()
    return {
        { handler = "onGesture", args = { { ges = "tap", pos = { x = 9, y = 9 }, text = "秘密章节" } } },
        { handler = "onGesture", args = { { ges = "swipe", direction = "west" } } },
    }, "extra"
end
local evs, extra = Input:waitEvent()
Assert.eq(extra, "extra")
Assert.len(evs, 2)
local input_line = logs[#logs]
Assert.is_true(input_line:find("book.diag input batch=2", 1, true) ~= nil)
Assert.is_true(input_line:find("kinds=Gesture:tap,Gesture:swipe:west", 1, true) ~= nil)
Assert.is_true(input_line:find("秘密章节", 1, true) == nil)
Assert.is_true(input_line:find("pos", 1, true) == nil)

-- 非数组表不伪造 batch 条数。
wait_impl = function()
    return { hello = "world" }
end
local before_n = #logs
Input:waitEvent()
Assert.eq(#logs, before_n)

-- 每次实际翻页写一行；开书首页只建基线；页码未变跳过；不额外 flush。
local flush_before = logs.flush or 0
before = #logs
clock.v = clock.v + 0.01
Diag.notePageUpdate(clock.v * 1000, 10)
Assert.eq(#logs, before, "开书首页不记翻页")
Assert.eq(logs.flush or 0, flush_before, "基线不额外 flush")

clock.v = clock.v + 1.2
Diag.notePageUpdate((clock.v - 0.01) * 1000, 11)
local page_line = logs[#logs]
Assert.is_true(page_line:find("book.diag page n=1 ", 1, true) ~= nil)
Assert.is_true(page_line:find("page=11", 1, true) ~= nil)
Assert.is_true(page_line:find("interval_ms=1200", 1, true) ~= nil)
Assert.is_true(page_line:find("update_ms=10", 1, true) ~= nil)
Assert.is_true(page_line:find("last=", 1, true) ~= nil)
Assert.is_true(page_line:find("uimanager.repaint:", 1, true) ~= nil)
Assert.is_true(page_line:find("input_batch=2", 1, true) ~= nil)
Assert.is_true(page_line:find("秘密", 1, true) == nil)
Assert.eq(logs.flush or 0, flush_before, "翻页路径不额外 flush")

before = #logs
clock.v = clock.v + 0.05
Diag.notePageUpdate(clock.v * 1000, 11)
Assert.eq(#logs, before, "页码未变不记翻页")

clock.v = clock.v + 0.05
Diag.notePageUpdate((clock.v - 0.008) * 1000, 12)
Assert.is_true(logs[#logs]:find("book.diag page n=2 ", 1, true) ~= nil)
Assert.is_true(logs[#logs]:find("page=12", 1, true) ~= nil)
Assert.is_true(logs[#logs]:find("interval_ms=100", 1, true) ~= nil)

-- 栏 / footer 记录：快路径不写，慢路径带 force/full。
local started = clock.v * 1000
clock.v = clock.v + 0.02
Diag.record("bars.clock", started)
Assert.is_true(logs[#logs]:find("bars.clock", 1, true) == nil)
started = clock.v * 1000
clock.v = clock.v + 0.18
Diag.record("footer.update", started, { force = true, full = true })
Assert.is_true(logs[#logs]:find("book.diag slow footer.update 180 ms force=true full=true", 1, true) ~= nil)

-- waitEvent 身份在 uninstall 后恢复；卸载后不再写日志。
local hooked = Input.waitEvent
Diag.uninstall()
Assert.is_false(Diag.isInstalled())
Assert.is_false(Diag.isEnabled())
Assert.is_true(Input.waitEvent ~= hooked)
check_impl = function(_self, ...)
    return "wait", 7, ...
end
Assert.eq(UIManager:_checkTasks(), "wait")
local after = #logs
wait_impl = function()
    return { { handler = "onGesture", args = { { ges = "tap" } } }, { handler = "onKeypress" } }
end
Input:waitEvent()
Assert.eq(#logs, after, "卸载后不再写 batch 日志")
Diag.record("bars.clock", 0)
Diag.notePageUpdate(0, 99)
Assert.eq(#logs, after, "卸载后不写诊断日志")

-- 再开可以重新安装；默认无需设置项。
Assert.is_true(Diag.install())
Assert.is_true(Diag.isInstalled())
Assert.is_true(Diag.isEnabled())
Diag.uninstall()
