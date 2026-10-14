--[[--
入口错误隔离：成功透传返回值；抛错写日志 + 弹错误页（可复制）并返回 nil；
错误页在屏上时不叠第二个；错误页起不来时原错误上抛。

@module tests.ui.guard_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, inject-field

local Assert = require("support.assert")

local logged = {}
local shown = {}
local clipboard
local toasts = 0
local viewer_broken = false

package.preload["utils.log"] = function()
    return {
        error = function(...) logged[#logged + 1] = table.concat({ ... }, " ") end,
        flush = function() end,
    }
end
package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(s) return s end end
package.preload["bookversion"] = function() return "1.2.3" end
package.preload["version"] = function()
    return { getShortVersion = function() return "2026.07" end }
end
package.preload["device"] = function()
    return { model = "KindlePW5", input = { setClipboardText = function(t) clipboard = t end } }
end
package.preload["ffi/util"] = function()
    return {
        template = function(fmt, ...)
            local args = { ... }
            return (fmt:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
        end,
    }
end
package.preload["ui.themes.widgets.toast"] = function()
    return { new = function(_, o) return { show = function() toasts = toasts + 1 end, text = o.text } end }
end
package.preload["ui.themes.widgets.text_viewer"] = function()
    return {
        new = function(_, o)
            if viewer_broken then error("theme broken") end
            function o:show() shown[#shown + 1] = self end
            function o:close() self.close_callback() end
            return o
        end,
    }
end

local Guard = require("ui.guard")

-- 成功：多返回值原样透传，不写日志不弹窗
local a, b = Guard.call("ok", function(x, y) return x + y, "two" end, 1, 2)
Assert.eq(a, 3)
Assert.eq(b, "two")
Assert.len(logged, 0)
Assert.len(shown, 0)

-- wrap 等价于 call，参数（含 self）透传
local obj = { n = 5 }
obj.get = Guard.wrap("get", function(self, k) return self.n * k end)
Assert.eq(obj:get(2), 10)

-- 抛错：返回 nil，日志含位置与堆栈，错误页带版本/设备/位置/原始错误
local r = Guard.call("feature bars.onCreate", function() error("boom") end)
Assert.is_nil(r)
Assert.len(logged, 1)
Assert.matches(logged[1], "feature bars%.onCreate")
Assert.matches(logged[1], "boom")
Assert.matches(logged[1], "stack traceback")
Assert.len(shown, 1)
local dialog = shown[1]
Assert.eq(dialog.title, "月读出错了")
for _, want in ipairs({ "1%.2%.3", "2026%.07", "KindlePW5", "feature bars%.onCreate", "boom" }) do
    Assert.matches(dialog.text, want)
end

-- 复制按钮：剪贴板拿到报告（不含给用户的引导语），并提示
dialog.buttons[2].callback()
Assert.matches(clipboard, "boom")
Assert.is_nil(clipboard:find("反馈给开发者", 1, true))
Assert.eq(toasts, 1)

-- 错误页还在：后续错误只记日志，不叠窗
Guard.call("again", function() error("second") end)
Assert.len(logged, 2)
Assert.len(shown, 1)

-- 关掉后，下一个错误重新弹
dialog.buttons[1].callback()
Guard.call("third", function() error("third") end)
Assert.len(shown, 2)
shown[2]:close()

-- 关闭月读：关错误页并关掉所有月读窗口
local closed_windows = 0
package.loaded["ui.exit_windows"] = { close = function() closed_windows = closed_windows + 1; return 1 end }
Guard.call("fourth", function() error("fourth") end)
local d3 = shown[#shown]
Assert.eq(d3.buttons[3].text, "关闭月读")
d3.buttons[3].callback()
Assert.eq(closed_windows, 1)
Guard.call("fifth", function() error("fifth") end)
Assert.eq(#shown, 4, "关闭后错误页可再次弹出")
shown[4]:close()
package.loaded["ui.exit_windows"] = nil

-- 错误页自身起不来：不吞，带着原始错误上抛
viewer_broken = true
local ok, err = pcall(Guard.call, "ui", function() error("original") end)
Assert.is_true(not ok)
Assert.matches(err, "original")
Assert.matches(err, "theme broken")

-- 上抛后 showing 复位：UI 恢复后仍能弹
viewer_broken = false
Guard.call("recover", function() error("x") end)
Assert.len(shown, 5)

-- paint：出错一次就停画该 label（重绘不再抛、不再弹），其它 label 照常
shown[#shown]:close()
local calls = 0
local function broken() calls = calls + 1 error("paint boom") end
local before_logs, before_shown = #logged, #shown
Guard.paint("bars.paintTo", broken)
Assert.eq(calls, 1)
Assert.len(shown, before_shown + 1)
Assert.matches(logged[#logged], "paint boom")
shown[#shown]:close()
Guard.paint("bars.paintTo", broken)
Guard.paint("bars.paintTo", broken)
Assert.eq(calls, 1, "坏掉的绘制器不再被调用")
Assert.len(logged, before_logs + 1)
Assert.len(shown, before_shown + 1)
local painted
Guard.paint("xray.paintTo", function(bb, x) painted = { bb, x } end, "bb", 3)
Assert.eq(painted[1], "bb")
Assert.eq(painted[2], 3)
