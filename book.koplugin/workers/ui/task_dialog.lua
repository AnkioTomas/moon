--[[--
后台任务的界面：任务列表弹窗 + 单个任务的前台进度弹窗，以及二者和顶栏共用的文案。

列表：随队列变化原地刷新（当前步骤、计数、进度条）。
点按可重跑的任务询问取消；点按其它地方（或任意键）收起，收起只关窗，不影响任务。

前台：任务入队后默认 `follow` 弹出进度窗，任务结束自动关窗；「后台运行」只关窗，
之后遇到等网络提示一次，结果仍由任务自己的 on_done 报告。可重跑的任务另有「取消」。

  TaskDialog:new{}:show()
  TaskDialog.start{ key = …, kind = …, title = …, run = … }   -- 入队 + 前台跟随，被拒时提示
  TaskDialog.follow(task)                                      -- 自行入队的调用方（书架同步）跟随进度

@module koplugin.book.workers.ui.task_dialog
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
local ProgressDialog = require("ui.themes.widgets.progress_dialog")
local ProgressWidget = require("ui/widget/progresswidget")
local Size = require("ui/size")
local Tasks = require("workers.tasks")
local TextWidget = require("ui/widget/textwidget")
local Toast = require("ui.themes.widgets.toast")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

local MAX_ROWS = 6

---@class BookTaskDialog : InputContainer
local TaskDialog = InputContainer:extend{}

--- 任务类型的显示名。
---@param kind BookTaskKind
---@return string
function TaskDialog.label(kind)
    return ({ download = _("下载"), sync = _("同步书架"), cache = _("缓存") })[kind]
end

--- 数值进度：download 按字节（MB），其余按条数；没有则 nil。
---@param task table BookTask 或 Tasks.tasks() 快照项
---@return string|nil
local function progressText(task)
    if task.kind == "download" then
        if task.count <= 0 then return nil end
        if task.total > 0 then
            return string.format("%.1f / %.1f MB", task.count / 1048576, task.total / 1048576)
        end
        return string.format("%.1f MB", task.count / 1048576)
    end
    if task.total > 0 then return tostring(task.count) .. "/" .. tostring(task.total) end
end

--- 状态一句话：排队 / 等网络 / 退避给状态；运行中给步骤 + 数值进度。brief 省掉步骤文案（顶栏用）。
---@param task table BookTask 或 Tasks.tasks() 快照项
---@param brief boolean|nil
---@return string
function TaskDialog.status(task, brief)
    if task.state == "queued" then return _("排队中") end
    if task.state == "waiting" then return _("等待网络") end
    if task.state == "retry_wait" then
        return brief and _("稍后重试") or T(_("第 %1 次失败，稍后重试"), task.attempt)
    end
    local progress = progressText(task)
    local text = not brief and task.text or nil
    if text and progress then return text .. " " .. progress end
    return text or progress or _("进行中")
end

--- 前台跟随一个任务：进度弹窗随队列刷新，任务结束（完成 / 取消）自动关窗。
--- 「后台运行」只关窗；转后台后进入等网络时提示一次；任务被同 key 新任务替换时也算结束、自动关窗。
---@param task BookTask Tasks.enqueue 返回的任务
function TaskDialog.follow(task)
    if task.done then return end
    local label = TaskDialog.label(task.kind)
    local name = task.title or label
    local open, last_state = true, task.state
    local watch
    local dialog = ProgressDialog:new{
        title = task.title and T(_("%1：%2"), label, task.title) or label,
        on_background = function()
            Toast:new{ text = _("已转到后台，可在顶栏查看进度"), timeout = 2 }:show()
        end,
        on_cancel = task.restartable and function() task.cancel() end or nil,
        close_callback = function() open = false end,
    }
    local function refresh()
        if task.done then
            watch.cancel()
            if open then dialog:close() end
            return
        end
        if open then
            dialog:set(TaskDialog.status(task), task.total > 0 and task.count * 100 / task.total or nil)
        elseif task.state == "waiting" and last_state ~= "waiting" then
            Toast:new{ text = T(_("「%1」等待网络，联网后继续"), name), timeout = 3 }:show()
        end
        last_state = task.state
    end
    watch = Tasks.watch(refresh)
    dialog:show()
    refresh()
end

--- 提示入队被拒的原因。
---@param reason "running"|"queue_full"
---@param spec BookTask 被拒的任务（取 title / kind）
function TaskDialog.rejected(reason, spec)
    Toast:new{
        text = reason == "running"
            and T(_("「%1」正在执行，请稍后再试"), spec.title or TaskDialog.label(spec.kind))
            or _("任务队列已满"),
        timeout = 3,
    }:show()
end

--- 用户发起任务的统一入口：入队并前台跟随；被拒时提示原因。
---@param spec BookTask
function TaskDialog.start(spec)
    local task, reason = Tasks.enqueue(spec)
    if not task then
        TaskDialog.rejected(reason, spec)
        return
    end
    TaskDialog.follow(task)
end

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
                text = TaskDialog.label(task.kind) .. " · " .. TaskDialog.status(task),
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
