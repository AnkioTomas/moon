--[[--
首页时钟：大时间 + 日期 + 农历；自己拉 myrl。

@module tests.ui.desktop.home.clock_spec
--]]

local Assert = require("support.assert")
local scheduled = {}
local paints = 0
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_, delay, fn) scheduled[fn] = delay end,
        unschedule = function(_, fn) scheduled[fn] = nil end,
        setDirty = function() paints = paints + 1 end,
    }
end

package.preload["gettext"] = function()
    return function(s) return s end
end
package.preload["ffi/blitbuffer"] = function()
    return { COLOR_BLACK = 0 }
end
package.preload["ui/geometry"] = function()
    return { new = function(_, opts)
        opts.getSize = function(self) return self.dimen or { w = self.width or 0, h = self.height or 0 } end
        return opts
    end }
end
package.preload["ui.components.bookui"] = function()
    return {
        sz = function(n) return n end,
        face = function() end,
        muted = function() return 1 end,
        dim = function() return 2 end,
    }
end
local function containerStub()
    return { new = function(_, opts)
        opts.getSize = function(self) return self.dimen or { w = self.width or 0, h = self.height or 0 } end
        return opts
    end }
end
package.preload["ui/widget/container/centercontainer"] = containerStub
package.preload["ui/widget/container/framecontainer"] = containerStub
package.preload["ui/widget/verticalgroup"] = containerStub
package.preload["ui/widget/verticalspan"] = containerStub

local text_widgets = {}
package.preload["ui/widget/textwidget"] = function()
    return {
        new = function(_, opts)
            local widget = { text = opts.text }
            function widget:setText(text) self.text = text end
            text_widgets[#text_widgets + 1] = widget
            return widget
        end,
    }
end

local myrl_cb
package.preload["online.myrl"] = function()
    return {
        fetch = function(_, _, cb)
            myrl_cb = cb
            return { cancel = function() end }
        end,
    }
end

local old_date = os.date
local now = { time = "10:20", sec = "20", day = "2026-09-10", w = "4" }
os.date = function(format)
    if format == "%H:%M" then return now.time end
    if format == "%S" then return now.sec end
    if format == "%Y-%m-%d" then return now.day end
    if format == "%w" then return now.w end
    return old_date(format)
end

local Clock = require("ui.desktop.home.views.clock")
local clock = Clock:new()
clock.lifecycle.state = "Resume"
clock:build({ desktop = {} }, { width = 320, height = 96, y = 10 })
Assert.eq(text_widgets[1].text, "10:20")
Assert.eq(text_widgets[2].text, "2026-09-10 星期四")
Assert.eq(text_widgets[3].text, "--")
Assert.is_nil(myrl_cb, "build must not fetch")
clock:onResume()
Assert.not_nil(myrl_cb)
myrl_cb({ lunar = "农历七月廿八", holiday = "中秋" })
Assert.eq(text_widgets[3].text, "农历七月廿八 · 中秋")
Assert.is_true(paints >= 1)

now.time = "10:21"
local before = paints
clock:onResume()
Assert.eq(text_widgets[1].text, "10:21")
Assert.is_true(paints > before)
Assert.not_nil(scheduled[clock._tick])
local tick = clock._tick
clock:onResume()
Assert.is_nil(scheduled[tick])
tick = clock._tick
clock:onPause()
Assert.is_nil(scheduled[tick])
clock:onResume()
Assert.not_nil(clock._tick, "暂停后可以直接恢复")
tick = clock._tick
clock:onPause()
clock:onDestroy()
Assert.is_nil(scheduled[tick])
Assert.is_nil(clock.time_widget)

os.date = old_date
return true
