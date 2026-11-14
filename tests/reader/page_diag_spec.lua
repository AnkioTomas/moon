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
local reader_settings = { refresh_diagnostics = false }
_G.G_reader_settings = {
    readSetting = function(_self, key)
        if key == "full_refresh_count" then return 0 end
        if key == "refresh_on_pages_with_images" then return false end
        return nil
    end,
}
package.loaded["utils.settings"] = {
    get = function() return reader_settings end,
}

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

-- Detailed refresh tracing is opt-in and leaves callback timing and native arguments intact.
local refresh_impl
local dirty_impl
UIManager._refresh_stack = {}
UIManager.refresh_count = 0
function UIManager:setDirty(...)
    return dirty_impl(self, ...)
end
function UIManager:_refresh(...)
    return refresh_impl(self, ...)
end
local native_dirty = UIManager.setDirty
local native_refresh = UIManager._refresh
local screen_args
local Screen = { waveform_partial = 8, waveform_full = 2 }
function Screen:mech_refresh(...)
    screen_args = { n = select("#", ...), ... }
    self.debug("mxc_update: 600x800 region @ (0, 0) with marker 9 (WFM: 8 & UPD: 1)")
    return "sent", nil, "native-result"
end
Screen.debug = function(message, ...)
    return message, nil, ...
end
local native_mech = Screen.mech_refresh
local native_debug = Screen.debug
package.loaded["device"].screen = Screen
Assert.is_true(Diag.install())
Assert.eq(UIManager.setDirty, native_dirty)
Assert.eq(UIManager._refresh, native_refresh)
Assert.eq(Screen.mech_refresh, native_mech)
Assert.eq(Screen.debug, native_debug)
Diag.uninstall()

reader_settings.refresh_diagnostics = true
Diag.install()
local wrapped_dirty = UIManager.setDirty
Diag.install()
Assert.eq(UIManager.setDirty, wrapped_dirty, "重复安装不叠包")
Assert.len(lines("refresh.start"), 1)
local region = { x = 0, y = 0, w = 600, h = 800 }
local private_widget = {
    name = "/private/secret-book.epub", title = "PRIVATE TITLE",
    paintTo = function() end,
}
local deferred_calls = 0
local deferred
dirty_impl = function(self, _widget, mode, rect, dither, extra)
    if type(mode) == "function" then
        deferred = mode
    elseif mode then
        self:_refresh(mode, rect, dither)
    end
    return true, nil, extra
end
refresh_impl = function(self, _mode, rect, dither)
    self.refresh_count = self.refresh_count + 1
    self._refresh_stack = { { mode = "full", region = rect, dither = dither } }
    return "queued", nil, rect
end
local dirty_a, dirty_b, dirty_c = UIManager:setDirty(private_widget, "partial", region, true, "extra")
Assert.is_true(dirty_a)
Assert.is_nil(dirty_b)
Assert.eq(dirty_c, "extra")
local dirty_lines = lines("refresh.dirty")
Assert.matches(dirty_lines[#dirty_lines], "mode=partial")
Assert.matches(dirty_lines[#dirty_lines], "source=page_diag_spec%.lua:")
local resolved = lines("refresh.resolve")
Assert.matches(resolved[#resolved], "requested=partial")
Assert.matches(resolved[#resolved], "queue=full@0,0,600,800:dither=true")
Assert.matches(resolved[#resolved], "count=0%->1")
Assert.is_nil(table.concat(logs, "\n"):find("secret-book", 1, true))
Assert.is_nil(table.concat(logs, "\n"):find("PRIVATE TITLE", 1, true))
Assert.is_nil(table.concat(logs, "\n"):find("/Users/", 1, true))

local callback = function()
    deferred_calls = deferred_calls + 1
    return "partial", region, false
end
UIManager:setDirty(nil, callback)
Assert.eq(deferred, callback, "传给 KOReader 的回调身份不变")
Assert.eq(deferred_calls, 0, "诊断不得提前执行 deferred 刷新")
dirty_lines = lines("refresh.dirty")
Assert.matches(dirty_lines[#dirty_lines], "mode=deferred")
Assert.matches(dirty_lines[#dirty_lines], "callback=page_diag_spec%.lua:")

check_impl = function() return nil end
UIManager:_checkTasks()
repaint_impl = function(self)
    local mode, rect, dither = deferred()
    self:_refresh(mode, rect, dither)
    Screen:mech_refresh(false, 8, 0, 0, 600, 800, false, "native-extra")
    self._refresh_stack = {}
    return nil, "repaint-result"
end
package.loaded["apps/reader/readerui"] = {
    instance = { document = { getDrawnImagesStatistics = function() return 1, 1 end } },
}
local paint_a, paint_b = UIManager:_repaint()
Assert.is_nil(paint_a)
Assert.eq(paint_b, "repaint-result")
Assert.eq(deferred_calls, 1)
Assert.len(lines("refresh.screen"), 1, "一次 native 调用只记一次，不数 Imp fallback")
Assert.matches(lines("refresh.screen")[1], "pending_requests=1%-2")
Assert.matches(lines("refresh.screen")[1], "flashing=false waveform=8")
Assert.matches(lines("refresh.screen")[1], "reader_images=1 reader_image_coverage=1")
Assert.matches(lines("refresh.driver")[1], "WFM: 8 & UPD: 1")
Assert.eq(screen_args.n, 8)
Assert.eq(screen_args[1], false)
Assert.eq(screen_args[2], 8)
Assert.eq(screen_args[8], "native-extra")

-- Pure refreshes (no dirty widget/afterPaint) and direct Screen calls remain visible.
local resolved_a, resolved_b, resolved_c = UIManager:_refresh("full", region, true)
Assert.eq(resolved_a, "queued")
Assert.is_nil(resolved_b)
Assert.eq(resolved_c, region)
Assert.matches(lines("refresh.resolve")[3], "pending_requests=none requested=full")
local sent_a, sent_b, sent_c = Screen:mech_refresh(true, 2, 0, 0, 600, 800, true)
Assert.eq(sent_a, "sent")
Assert.is_nil(sent_b)
Assert.eq(sent_c, "native-result")
Assert.matches(lines("refresh.screen")[2], "pending_requests=none flashing=true waveform=2")
local debug_a, debug_b, debug_c = Screen.debug("ordinary debug", "extra")
Assert.eq(debug_a, "ordinary debug")
Assert.is_nil(debug_b)
Assert.eq(debug_c, "extra")
Assert.len(lines("refresh.driver"), 2, "不放大其它驱动 debug")
Screen.debug("MXCFB_SEND_UPDATE ioctl failed:", "test-error")
Assert.matches(lines("refresh.driver")[3], "test%-error")

-- Non-file Lua chunks may contain user data: never log their source text.
local chunk = assert(loadstring("return function() return 'PRIVATE CHUNK' end"))()
UIManager:setDirty("all", chunk)
Assert.matches(lines("refresh.dirty")[3], "callback=lua%-chunk")
Assert.is_nil(table.concat(logs, "\n"):find("PRIVATE CHUNK", 1, true))
refresh_impl = function() error("refresh-boom") end
Assert.errors(function() UIManager:_refresh("partial", region) end, "refresh%-boom")

-- A later third-party wrapper is not overwritten during uninstall.
local previous_mech = Screen.mech_refresh
local later_mech = function(self, ...) return previous_mech(self, ...) end
Screen.mech_refresh = later_mech
Diag.uninstall()
Assert.eq(Screen.mech_refresh, later_mech)
Assert.eq(UIManager.setDirty, native_dirty)
Assert.eq(UIManager._refresh, native_refresh)
Assert.eq(Screen.debug, native_debug)
local ended = #logs
Screen.debug("MXCFB_SEND_UPDATE ioctl failed:", "after-uninstall")
Screen:mech_refresh(false, 8, 0, 0, 600, 800, false)
Assert.eq(#logs, ended)
local screen_before = #lines("refresh.screen")
local driver_before = #lines("refresh.driver")
Diag.install()
Screen:mech_refresh(false, 8, 0, 0, 600, 800, false)
Assert.eq(#lines("refresh.screen"), screen_before + 1, "重装不能复活嵌在别人 wrapper 里的旧钩子")
Assert.eq(#lines("refresh.driver"), driver_before + 1)
Diag.uninstall()
reader_settings.refresh_diagnostics = false
