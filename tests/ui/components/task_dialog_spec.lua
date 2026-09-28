--[[--
后台任务列表弹窗：随队列原地刷新、尺寸变化才刷下层、只能取消可重跑的任务、关窗注销订阅。

@module tests.ui.components.task_dialog_spec
--]]

local Assert = require("support.assert")

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
package.preload["ffi/blitbuffer"] = function() return { COLOR_WHITE = 0, COLOR_BLACK = 1 } end
package.preload["ui/font"] = function() return { getFace = function() return {} end } end
package.preload["ui/size"] = function()
    return {
        padding = { default = 4, large = 8 },
        margin = { tiny = 1 },
        radius = { window = 4 },
        border = { window = 2 },
    }
end
package.preload["ui/network/manager"] = function()
    return { isConnected = function() return true end }
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
package.preload["ui/widget/textwidget"] = leaf(10)
package.preload["ui/widget/progresswidget"] = leaf(5)
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
package.preload["ui/widget/container/framecontainer"] = box
package.preload["ui/widget/container/centercontainer"] = box
package.preload["ui/widget/container/inputcontainer"] = function()
    return {
        extend = function(_, cls)
            cls.__index = cls
            cls.new = function(c, o)
                o = setmetatable(o or {}, c)
                o.key_events, o.ges_events = {}, {}
                o:init()
                return o
            end
            return cls
        end,
    }
end
local confirm
package.preload["ui/widget/confirmbox"] = function()
    return { new = function(_, o) confirm = o; return o end }
end

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

local Tasks = require("tasks")
local runs = {}
local function spec(key, restartable)
    return {
        key = key, lane = key, label = "缓存", title = "书" .. key, restartable = restartable,
        run = function(report, done)
            runs[key] = { report = report, done = done }
            return { cancel = function() runs[key].cancelled = true end }
        end,
    }
end
Tasks.enqueue(spec("a", true))
Tasks.enqueue(spec("b", false))
flush()

local TaskDialog = require("ui.components.task_dialog")
local dialog = TaskDialog:new{}
dialog:show()
Assert.eq(shown[#shown], dialog)
Assert.eq(#dialog.rows, 2)
Assert.eq(dialog.rows[1].title, "书a")
Assert.is_true(dialog.rows[1].restartable)
Assert.is_false(dialog.rows[2].restartable)
local status = dialog.rows[1].frame[1][2].text
Assert.eq(status, "缓存 · 进行中")

-- 出现进度条：高度变了，连同旧区域刷下层。
dialog.frame.dimen = setmetatable({ x = 0, y = 0, w = 100, h = dialog.frame:getSize().h }, Rect)
runs.a.report("第 3 章", 3, 10)
flush()
Assert.eq(dirty[#dirty].widget, "all")
Assert.eq(dialog.rows[1].frame[1][2].text, "缓存 · 第 3 章 3/10")
Assert.eq(#dialog.rows[1].frame[1], 3, "有 total 才画进度条")

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
confirm = nil
Assert.is_true(dialog:onTap(nil, { pos = setmetatable({ x = 5, y = 50, w = 0, h = 0 }, Rect) }))
Assert.is_nil(confirm)
Assert.eq(#closed, 0)

-- 点可重跑的任务行：确认后取消任务，弹窗随队列刷新。
Assert.is_true(dialog:onTap(nil, { pos = setmetatable({ x = 5, y = 5, w = 0, h = 0 }, Rect) }))
Assert.eq(confirm.text, "取消任务「书a」？")
confirm.ok_callback()
Assert.is_true(runs.a.cancelled)
Assert.is_nil(Tasks.get("a"))
flush()
Assert.eq(#dialog.rows, 1)

-- 点空白收起；关窗注销订阅，之后队列变化不再重建。
Assert.is_true(dialog:onTap(nil, { pos = setmetatable({ x = 500, y = 700, w = 0, h = 0 }, Rect) }))
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

return true
