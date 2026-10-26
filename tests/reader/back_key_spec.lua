--[[-- 阅读返回键：只在正文顶层接按键，不改变返回动作与选区的原生处理。
@module tests.reader.back_key_spec
--]]

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local InputContainer = require("ui/widget/container/inputcontainer")
local conf = {}
Kit.sections.reader = conf
local opened, closed, native, selected = 0, 0, 0, false
package.preload["desktop"] = function()
    return {
        ensureFileManager = function()
            Assert.is_true(closed > opened, "先正常关书，再重建文件管理器")
            return { book = {} }
        end,
        open = function() opened = opened + 1 end,
    }
end
local ReaderExit = require("desktop.reader_exit")
local reader = InputContainer:new{
    link = { isPageLinkSelected = function() return selected end },
    onClose = function() closed = closed + 1 end,
    onBack = function() native = native + 1; return true end,
}
reader.dialog = reader
reader.key_events.Back = { { { "Back" } } }
local function key(name, modified)
    return {
        match = function(_self, sequence)
            if modified then return false end
            if type(sequence[1]) == "string" then return sequence[1] == name end
            for _idx, value in ipairs(sequence[1]) do
                if value == name then return true end
            end
            return false
        end,
    }
end
local back = Event:new("KeyPress", key("Back"))
ReaderExit.attach(reader)
local installed = reader.onKeyPress
ReaderExit.attach(reader)
Assert.eq(reader.onKeyPress, installed, "同一阅读器只接一次")
UIManager:show(reader)
Assert.is_true(reader:handleEvent(back))
Assert.eq(native, 1, "缺省关闭，保留原生行为")
Assert.eq(closed, 0)
conf.back_to_desktop = true
Assert.is_true(reader:handleEvent(Event:new("Back")), "手势发送的 Back 动作仍走原生")
Assert.eq(native, 2)
reader:handleEvent(Event:new("KeyPress", key("LPgBack")))
reader:handleEvent(Event:new("KeyPress", key("Back", true)))
Assert.eq(closed, 0, "上一页与组合快捷键不是返回键")

local overlay = {}
UIManager:show(overlay)
reader:handleEvent(back)
Assert.eq(closed, 0, "弹窗或键盘盖住正文时不得关书")
UIManager:close(overlay)
selected = true
reader:handleEvent(back)
Assert.eq(native, 3, "已选链接仍由原生返回处理")
Assert.eq(closed, 0)
selected = false
reader[1] = InputContainer:new{ onKeyPress = function() return true end }
reader:handleEvent(back)
Assert.eq(closed, 0, "正文内部选区模块优先处理按键")
reader[1] = nil

local pending
UIManager.nextTick = function(_self, callback) pending = callback end
Assert.is_true(reader:handleEvent(Event:new("KeyRepeat", key("Back"))))
Assert.is_nil(pending, "长按重复不触发关书")
Assert.is_true(reader:handleEvent(back))
Assert.eq(closed, 0, "不能在按键分发调用栈内关文档")
Assert.not_nil(pending)
reader:handleEvent(Event:new("KeyRepeat", key("Back")))
pending()
Assert.eq(closed, 1)
Assert.eq(opened, 1)
conf.back_to_desktop = false
reader:handleEvent(back)
Assert.eq(native, 4, "关闭开关立即恢复原生行为")
Assert.eq(closed, 1)
