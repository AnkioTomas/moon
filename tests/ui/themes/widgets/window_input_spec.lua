--[[-- 顶层窗口输入：按键、映射、滑动共用分页；循环边界与不可关闭窗口不穿透。
@module tests.ui.themes.widgets.window_input_spec
--]]

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local Modal = require("ui.themes.widgets.modal")
local List = require("ui.themes.widgets.list")
local Pager = require("ui.themes.widgets.pager")
local ProgressDialog = require("ui.themes.widgets.progress_dialog")
local TextViewer = require("ui.themes.widgets.text_viewer")

local function key(name)
    return {
        match = function(_self, sequence)
            for _idx, part in ipairs(sequence) do
                if type(part) == "table" then
                    local found = false
                    for _j, value in ipairs(part) do if name == value then found = true end end
                    if not found then return false end
                elseif part ~= name then
                    return false
                end
            end
            return true
        end,
    }
end

local function swipe(direction)
    local ges = Kit.tap(1, 1)
    ges.ges, ges.direction = "swipe", direction
    return Event:new("Gesture", ges)
end

local items = {}
for i = 1, 60 do items[i] = { text = tostring(i) } end
local lower = List:new{ items = items }
lower:show()
local upper = List:new{ items = items }
upper:show()
Assert.is_false(require("device"):hasKeys(), "纯触屏也要响应外接翻页键")
Assert.is_true(upper:handleEvent(Event:new("KeyPress", key("RPgFwd"))))
Assert.eq(upper.page, 2)
Assert.eq(lower.page, 1)
Assert.is_false(lower:handleEvent(Event:new("KeyPress", key("RPgFwd"))), "被覆盖的窗口不能响应按键")
Assert.is_false(lower:handleEvent(Event:new("BookWindowPage", 1)), "映射动作也必须检查顶层")
Assert.is_true(upper:handleEvent(swipe("east")))
Assert.eq(upper.page, 1)

upper:goPage(upper:pages())
Assert.is_true(upper:handleEvent(Event:new("BookWindowPage", 1)))
Assert.eq(upper.page, upper:pages(), "到末页吞事件，不漏给下层")
Kit.display.pager_cycle = true
upper:handleEvent(Event:new("KeyPress", key("LPgFwd")))
Assert.eq(upper.page, 1, "末页按键循环到首页")
upper:handleEvent(swipe("east"))
Assert.eq(upper.page, upper:pages(), "首页右滑循环到末页")
upper:goPage(1)
local left = Kit.find(upper, function(w) return w.icon == "chevron_left" end)[1]
Assert.is_true(left.enabled)
left.callback()
Assert.eq(upper.page, upper:pages(), "按钮与按键、滑动使用相同循环规则")
Assert.eq(lower.page, 1)

Kit.display.pager_keys = false
local page = upper.page
upper:handleEvent(Event:new("KeyPress", key("RPgBack")))
Assert.eq(upper.page, page, "关闭原始按键后不翻页、不穿透")
upper:handleEvent(Event:new("BookWindowPage", -1))
Assert.eq(upper.page, page - 1, "显式映射仍可用")
Kit.display.pager_swipe = false
page = upper.page
upper:handleEvent(swipe("west"))
Assert.eq(upper.page, page)
Kit.display.pager_keys, Kit.display.pager_swipe = true, true

Kit.display.modal_keys = false
upper:handleEvent(Event:new("KeyPress", key("Back")))
Assert.eq(UIManager._window_stack[#UIManager._window_stack].widget, upper)
upper:handleEvent(Event:new("BookWindowClose"))
Assert.eq(UIManager._window_stack[#UIManager._window_stack].widget, lower, "显式关闭只移除顶层")
local closed = #Kit.closed
Kit.display.modal_keys = true
lower:handleEvent(Event:new("KeyRepeat", key("Back")))
Assert.eq(#Kit.closed, closed, "长按返回键的重复事件不能连关多层")

local backgrounded = 0
local progress = ProgressDialog:new{ text = "处理中", on_background = function() backgrounded = backgrounded + 1 end }
progress:show()
progress:handleEvent(Event:new("BookWindowClose"))
Assert.eq(backgrounded, 1, "关闭动作保留转后台语义")
progress = ProgressDialog:new{ text = "不可取消", dismissable = false }
progress:show()
closed = #Kit.closed
progress:handleEvent(Event:new("BookWindowClose"))
progress:handleEvent(swipe("south"))
progress:handleEvent(Event:new("KeyPress", key("Back")))
Assert.eq(#Kit.closed, closed, "不可取消窗口不能被新输入绕过")
Assert.eq(lower.page, 1)
progress:close()

-- 内嵌 List 可以翻页，但不能响应关闭自身；关闭由顶层宿主处理。
local host = Modal:new{}
local embedded = List:new{ items = items, show_parent = host }
host:setPanel(embedded)
host:show()
host:handleEvent(Event:new("KeyPress", key("RPgFwd")))
Assert.eq(embedded.page, 2)
host:handleEvent(Event:new("BookWindowClose"))
Assert.eq(Kit.closed[#Kit.closed], host)
Assert.eq(UIManager._window_stack[#UIManager._window_stack].widget, lower)

-- 未拉完的数据不循环到未知末页，向前仍能触发加载下一批。
local requested
local lazy = Modal:new{}
lazy:setPanel(Pager.widget{
    width = 300, page = 1, pages = 3, cycle = false,
    range = lazy.dimen, on_page = function(p) requested = p end,
})
lazy:show()
lazy:handleEvent(Event:new("BookWindowPage", -1))
Assert.is_nil(requested)
lazy:handleEvent(Event:new("BookWindowPage", 1))
Assert.eq(requested, 2)
lazy:close()

-- 翻回文本首尾时同步滚动正文，不能只循环页码。
local viewer = TextViewer:new{ title = "日志", text = string.rep("内容", 4000) }
viewer:show()
viewer:handleEvent(Event:new("BookWindowPage", -1))
Assert.eq(viewer.page, viewer.pages)
Assert.is_true(viewer.body.scrolled > 0)
viewer:handleEvent(Event:new("BookWindowPage", 1))
Assert.eq(viewer.page, 1)
Assert.eq(viewer.body.scrolled, 0)
Kit.display.swipe_dismiss = "off"
local no_swipe = List:new{ items = items }
no_swipe:show()
closed = #Kit.closed
no_swipe:handleEvent(swipe("south"))
Assert.eq(#Kit.closed, closed, "保留用户关闭滑动关窗的设置")
no_swipe:handleEvent(swipe("west"))
Assert.eq(no_swipe.page, 2, "关闭滑动关窗不影响水平分页")
Assert.is_nil(no_swipe:handleEvent(Event:new("KeyPress", key("CustomKey"))), "不抢用户其它快捷键")
local multi = Kit.tap(1, 1)
multi.ges, multi.multiswipe_directions = "multiswipe", "west north"
Assert.is_nil(no_swipe:handleEvent(Event:new("Gesture", multi)), "不抢用户自定义多段手势")
local InputContainer = require("ui/widget/container/inputcontainer")
local onGesture = InputContainer.onGesture
InputContainer.onGesture = function() return nil end
page = no_swipe.page
no_swipe:handleEvent(swipe("west"))
Assert.eq(no_swipe.page, page, "沿用 KOReader 禁用触摸过滤，不另开手势通道")
InputContainer.onGesture = onGesture
local native = {}
UIManager:show(native)
Assert.is_false(no_swipe:handleEvent(Event:new("BookWindowClose")), "原生菜单盖住月读时也不处理")
Assert.is_false(no_swipe:handleEvent(Event:new("BookWindowPage", 1)))
UIManager:close(native)
local empty = List:new{ items = {} }
empty:show()
empty:handleEvent(Event:new("BookWindowPage", 1))
empty:handleEvent(swipe("west"))
Assert.eq(empty.page, 1, "空列表与单页不循环到无效页")
