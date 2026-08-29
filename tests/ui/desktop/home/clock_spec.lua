--[[--
首页时钟：构建后可原地更新文本。

@module tests.ui.desktop.home.clock_spec
--]]

local Assert = require("support.assert")

package.preload["gettext"] = function()
    return function(s) return s end
end
package.preload["ffi/blitbuffer"] = function()
    return { COLOR_BLACK = 0 }
end
package.preload["ui/geometry"] = function()
    return { new = function(_, opts) return opts end }
end
package.preload["ui.components.bookui"] = function()
    return {
        sz = function(n) return n end,
        face = function(_, size) return size end,
        muted = function() return 1 end,
    }
end
local function containerStub()
    return { new = function(_, opts) return opts end }
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

local old_date = os.date
local now = { time = "10:20", date = "2026-08-29", wday = "6" }
os.date = function(format)
    if format == "%H:%M" then return now.time end
    if format == "%Y-%m-%d" then return now.date end
    if format == "%w" then return now.wday end
    return old_date(format)
end

local Clock = require("ui.desktop.home.components.clock")
local part = Clock.build({}, {}, { width = 320 })
Assert.eq(text_widgets[1].text, "10:20")
Assert.eq(text_widgets[2].text, "2026-08-29 星期六")

now.time, now.date, now.wday = "10:21", "2026-08-30", "0"
part.refresh()
Assert.eq(text_widgets[1].text, "10:21")
Assert.eq(text_widgets[2].text, "2026-08-30 星期日")

os.date = old_date
