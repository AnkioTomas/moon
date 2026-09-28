--[[--
后台任务列表弹窗：随队列变化原地刷新（当前步骤、计数、进度条）。
点按可重跑的任务询问取消；点按其它地方（或任意键）收起，收起只关窗，不影响任务。

  TaskDialog:new{}:show()

@module koplugin.book.ui.components.task_dialog
--]]

require("l10n").apply()

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local ProgressWidget = require("ui/widget/progresswidget")
local Size = require("ui/size")
local Tasks = require("tasks")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

local MAX_ROWS = 6

---@param task table Tasks.tasks() 快照项
---@return string
local function statusText(task)
    local status
    if task.state == "queued" then
        status = _("等待中")
    elseif task.state == "waiting" then
        status = _("等待网络")
    elseif task.state == "retry_wait" then
        status = T(_("第 %1 次失败，稍后重试"), task.attempt)
    else
        status = task.text or _("进行中")
    end
    if task.total > 0 then
        status = status .. " " .. tostring(task.count) .. "/" .. tostring(task.total)
    end
    return task.label .. " · " .. status
end

---@class BookTaskDialog
local TaskDialog = InputContainer:extend{}

function TaskDialog:init()
    self.dimen = Screen:getSize()
    if Device:hasKeys() then
        self.key_events.AnyKeyPressed = { { Device.input.group.Any } }
    end
    if Device:isTouchDevice() then
        self.ges_events.Tap = {
            GestureRange:new{
                ges = "tap",
                range = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() },
            },
        }
    end
    self.width = Screen:getWidth() - Screen:scaleBySize(80)
    self:build()
    self.watch = Tasks.watch(function() self:refresh() end)
end

--- 按当前快照重建内容；行框在绘制后才有 dimen，点按时再比对。
function TaskDialog:build()
    local width = self.width
    -- 定宽：文案长短变化不改变弹窗尺寸，进度刷新只需刷原区域。
    local group = VerticalGroup:new{ align = "left", HorizontalSpan:new{ width = width } }
    group[2] = TextWidget:new{
        text = _("后台任务"),
        face = Font:getFace("ffont"),
        bold = true,
        max_width = width,
    }
    self.rows = {}
    local tasks = Tasks.tasks()
    for i = 1, math.min(#tasks, MAX_ROWS) do
        local task = tasks[i]
        local body = VerticalGroup:new{
            align = "left",
            TextWidget:new{
                text = task.title or "",
                face = Font:getFace("smallffont"),
                bold = true,
                max_width = width,
            },
            TextWidget:new{
                text = statusText(task),
                face = Font:getFace("smallffont"),
                max_width = width,
            },
        }
        if task.total > 0 then
            body[#body + 1] = ProgressWidget:new{
                width = width,
                height = Screen:scaleBySize(8),
                margin_h = 0,
                margin_v = Size.margin.tiny,
                fillcolor = Blitbuffer.COLOR_BLACK,
                percentage = math.min(task.count / task.total, 1),
            }
        end
        local row = FrameContainer:new{
            bordersize = 0,
            padding = 0,
            padding_top = Size.padding.default,
            body,
        }
        self.rows[#self.rows + 1] = { frame = row, key = task.key, title = task.title, restartable = task.restartable }
        group[#group + 1] = row
    end
    if #tasks > MAX_ROWS then
        group[#group + 1] = VerticalSpan:new{ width = Size.padding.default }
        group[#group + 1] = TextWidget:new{
            text = T(_("还有 %1 个任务"), #tasks - MAX_ROWS),
            face = Font:getFace("smallffont"),
            max_width = width,
        }
    elseif #tasks == 0 then
        group[#group + 1] = VerticalSpan:new{ width = Size.padding.default }
        group[#group + 1] = TextWidget:new{
            text = _("当前没有后台任务"),
            face = Font:getFace("smallffont"),
            max_width = width,
        }
    end
    self.frame = FrameContainer:new{
        radius = Size.radius.window,
        bordersize = Size.border.window,
        padding = Size.padding.large,
        background = Blitbuffer.COLOR_WHITE,
        group,
    }
    self[1] = CenterContainer:new{ dimen = Screen:getSize(), self.frame }
end

--- 队列变化：重建；尺寸没变只刷弹窗区域，变了（增删任务、出现进度条）连同旧区域一起刷下层。
function TaskDialog:refresh()
    local old = self.frame.dimen and self.frame.dimen:copy()
    local old_h = self.frame:getSize().h
    self:build()
    if old and old_h == self.frame:getSize().h then
        UIManager:setDirty(self, function() return "fast", old end)
        return
    end
    UIManager:setDirty("all", function()
        local now = self.frame.dimen
        return "ui", old and now and old:combine(now) or now or old
    end)
end

function TaskDialog:show()
    UIManager:show(self, "ui")
end

function TaskDialog:close()
    UIManager:close(self, "ui")
end

--- 点中可重跑的任务行询问取消，其它位置收起。
function TaskDialog:onTap(_arg, ges)
    for _i, row in ipairs(self.rows) do
        if row.frame.dimen and ges.pos:intersectWith(row.frame.dimen) then
            if row.restartable then self:confirmCancel(row) end
            return true
        end
    end
    self:close()
    return true
end

---@param row { key: string, title: string|nil }
function TaskDialog:confirmCancel(row)
    UIManager:show(require("ui/widget/confirmbox"):new{
        text = T(_("取消任务「%1」？"), row.title or ""),
        ok_text = _("取消任务"),
        cancel_text = _("继续"),
        ok_callback = function()
            local task = Tasks.get(row.key)
            if task then task.cancel() end
        end,
    })
end

function TaskDialog:onAnyKeyPressed()
    self:close()
    return true
end

function TaskDialog:onCloseWidget()
    if self.watch then
        self.watch.cancel()
        self.watch = nil
    end
end

return TaskDialog
