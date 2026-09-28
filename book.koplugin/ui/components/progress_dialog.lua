--[[--
进度弹窗：标题 + 当前步骤 + 进度条，步骤文字与进度随后台事件实时更新。

KOReader 的 ProgressbarDialog 建好后改不了文字，这里只多一个 update。
点按任意处（或任意键）收起，收起只关窗，不影响后台任务。

  local dialog = ProgressDialog:new{ title = "…", dismiss_callback = fn }
  dialog:show()
  dialog:update("正在上传 a.epub", 3, 9)   -- done/total 可省略，省略时进度条不动

@module koplugin.book.ui.components.progress_dialog
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local ProgressWidget = require("ui/widget/progresswidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

---@class BookProgressDialog
---@field title string
---@field dismiss_callback fun()|nil 关窗（完成 / 用户收起）时调用一次
local ProgressDialog = InputContainer:extend{
    title = nil,
    dismiss_callback = nil,
}

function ProgressDialog:init()
    self.align = "center"
    self.dimen = Screen:getSize()
    if Device:hasKeys() then
        self.key_events.AnyKeyPressed = { { Device.input.group.Any } }
    end
    if Device:isTouchDevice() then
        self.ges_events.TapClose = {
            GestureRange:new{
                ges = "tap",
                range = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() },
            },
        }
    end
    local width = Screen:getWidth() - Screen:scaleBySize(80)
    self.detail = TextWidget:new{
        text = _("正在准备…"),
        face = Font:getFace("smallffont"),
        max_width = width,
    }
    self.bar = ProgressWidget:new{
        fillcolor = Blitbuffer.COLOR_BLACK,
        width = width,
        height = Screen:scaleBySize(18),
        padding = Size.padding.large,
        margin = Size.margin.tiny,
        percentage = 0,
    }
    self.frame = FrameContainer:new{
        radius = Size.radius.window,
        bordersize = Size.border.window,
        padding = Size.padding.large,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            TextWidget:new{
                text = self.title,
                face = Font:getFace("ffont"),
                bold = true,
                max_width = width,
            },
            self.detail,
            self.bar,
        },
    }
    self[1] = self.frame
end

--- 换成当前步骤；给了 total 时进度条按 done/total 走，否则保持不动。
---@param text string
---@param done integer|nil
---@param total integer|nil
function ProgressDialog:update(text, done, total)
    total = tonumber(total)
    if total and total > 0 then
        done = math.min(tonumber(done) or 0, total)
        self.detail:setText(T(_("%1（%2/%3）"), text, done, total))
        self.bar:setPercentage(done / total)
    else
        self.detail:setText(text)
    end
    UIManager:setDirty(self, function() return "fast", self.frame.dimen end)
end

function ProgressDialog:show()
    UIManager:show(self, "ui")
end

function ProgressDialog:close()
    UIManager:close(self, "ui")
end

function ProgressDialog:onTapClose()
    self:close()
    return true
end

ProgressDialog.onAnyKeyPressed = ProgressDialog.onTapClose

function ProgressDialog:onCloseWidget()
    local cb = self.dismiss_callback
    self.dismiss_callback = nil
    if cb then cb() end
end

return ProgressDialog
