--[[--
后台任务的界面：任务列表弹窗 + 单个任务的前台进度弹窗，以及二者共用的文案。

列表：主题弹窗，每条任务一行，按屏高分页（翻页条 + 左右滑），随队列变化原地刷新：

  +--------------------------------+
  | 后台任务                        |
  | 缓存：书名                 进行中 |
  | 第 3 章 3/10                    |
  | [██████████····················] |
  |--------------------------------|
  | 下载：词库                 已完成 |
  | [<]          1 / 2          [>] |
  +--------------------------------+

未结束任务之后列出最近结束的任务（已完成 / 失败）。点按可重跑的未结束任务询问取消；
点面板外或返回键收起，收起只关窗，不影响任务。

前台：任务入队后默认 `follow` 弹出进度窗，任务结束自动关窗；「后台运行」只关窗，
之后遇到等网络提示一次，结果仍由任务自己的 on_done 报告。可重跑的任务另有「取消」。

  TaskDialog:new{}:show()
  TaskDialog.start{ key = …, kind = …, title = …, run = … }   -- 入队 + 前台跟随，被拒时提示
  TaskDialog.follow(task)                                      -- 自行入队的调用方（书架同步）跟随进度

@module koplugin.book.workers.ui.task_dialog
--]]

require("l10n").apply()

local BD = require("ui/bidi")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local RightContainer = require("ui/widget/container/rightcontainer")
local Blitbuffer = require("ffi/blitbuffer")
local Tasks = require("workers.tasks")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Theme = require("ui.themes")
local Confirm = require("ui.themes.widgets.confirm")
local Modal = require("ui.themes.widgets.modal")
local Pager = require("ui.themes.widgets.pager")
local Progress = require("ui.themes.widgets.progress")
local ProgressDialog = require("ui.themes.widgets.progress_dialog")
local Tap = require("ui.themes.widgets.tap")
local Text = require("ui.themes.widgets.text")
local Toast = require("ui.themes.widgets.toast")
local _ = require("gettext")
local T = require("ffi/util").template

---@class BookTaskDialog : BookThemeModal
---@field page integer
---@field per_page integer
local TaskDialog = Modal:extend{}

--- 任务类型的显示名。
---@param kind BookTaskKind
---@return string
function TaskDialog.label(kind)
    return ({ download = _("下载"), sync = _("同步书架"), cache = _("缓存"), online = _("在线"), ai = _("AI 分析") })[kind]
end

--- 「类型：书名」，没有书名只给类型。
---@param task table BookTask 或快照项
---@return string
local function heading(task)
    local label = TaskDialog.label(task.kind)
    return task.title and T(_("%1：%2"), label, task.title) or label
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

--- 进度描述：步骤文案 + 数值进度；都没有则 nil。
---@param task table
---@return string|nil
local function detail(task)
    local progress = progressText(task)
    if task.text and progress then return task.text .. " " .. progress end
    return task.text or progress
end

--- 状态短词（列表右侧）。
---@param task table
---@return string
local function state(task)
    if task.state == "finished" then return task.ok and _("已完成") or _("失败") end
    return ({ queued = _("排队中"), waiting = _("等待网络"), retry_wait = _("稍后重试"), running = _("进行中") })[task.state]
end

--- 状态一句话（前台进度窗）：运行中给进度描述，退避给第几次失败，其余同状态短词。
---@param task table BookTask 或 Tasks.tasks() 快照项
---@return string
function TaskDialog.status(task)
    if task.state == "retry_wait" then return T(_("第 %1 次失败，稍后重试"), task.attempt) end
    if task.state == "running" then return detail(task) or state(task) end
    return state(task)
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
        title = heading(task),
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

--- 一条任务：左侧任务名 / 进度描述、右侧状态，下面通栏进度条与分隔线。高度与内容无关，翻页按固定行高算。
---@param task table 快照项
---@return table
function TaskDialog:row(task)
    local t = self.theme
    local gap = Theme.px(t.space.sm)
    local status_w = math.floor(self.inner * 0.25)
    local left_w = self.inner - status_w - gap
    local muted = t.color.muted
    local percent = task.state == "finished" and task.ok and 100
        or task.total > 0 and task.count * 100 / task.total or 0
    local left = VerticalGroup:new{
        align = "left",
        Text.line("body", heading(task), { width = left_w, bold = true }),
        VerticalSpan:new{ width = Theme.px(t.space.xs) },
        Text.line("caption", detail(task) or " ", { width = left_w, color = muted }),
    }
    local h = left:getSize().h
    local row = VerticalGroup:new{
        align = "left",
        VerticalSpan:new{ width = gap },
        HorizontalGroup:new{
            align = "center",
            LeftContainer:new{ dimen = Geom:new{ w = left_w, h = h }, left },
            HorizontalSpan:new{ width = gap },
            RightContainer:new{
                dimen = Geom:new{ w = status_w, h = h },
                Text.line("body", state(task), { width = status_w,
                    color = task.state == "finished" and muted or t.color.ink }),
            },
        },
        VerticalSpan:new{ width = Theme.px(t.space.xs) },
        Progress:new{ width = self.inner, percent = percent },
        VerticalSpan:new{ width = gap },
        LineWidget:new{
            background = Blitbuffer.Color8(t.color.rule),
            dimen = Geom:new{ w = self.inner, h = Theme.px(t.row.divider) },
        },
    }
    return Tap.wrap(row, task.restartable and task.state ~= "finished"
        and function() TaskDialog.confirmCancel(task) end or nil)
end

function TaskDialog:init()
    Modal.init(self)
    local t = self.theme
    self.inner = self:innerWidth()
    self.page = 1
    local pitch = self:row({ kind = "cache", state = "queued", count = 0, total = 0 }):getSize().h
    local chrome = Theme.px(t.control.height) + Theme.px(t.space.lg) * 4 + Theme.px(t.font.title * 2)
    self.per_page = math.max(1, math.floor((self.dimen.h - chrome) / pitch))
    self.pitch = pitch
    self.ges_events.SwipeTasks = { GestureRange:new{ ges = "swipe", range = self.dimen } }
    self:rebuild()
    self.watch = Tasks.watch(function() self:refresh() end)
end

--- 未结束的在前，最近结束的在后。
---@return table[]
local function snapshots()
    local out = Tasks.tasks()
    for _idx, task in ipairs(Tasks.finished()) do out[#out + 1] = task end
    return out
end

--- 按当前页重建面板；页码越界夹到末页。
function TaskDialog:rebuild()
    local tasks = snapshots()
    local pages = math.max(1, math.ceil(#tasks / self.per_page))
    self.page = math.max(1, math.min(self.page, pages))
    local body = VerticalGroup:new{ align = "left" }
    local first = (self.page - 1) * self.per_page
    local last = math.min(#tasks, first + self.per_page)
    for i = first + 1, last do body[#body + 1] = self:row(tasks[i]) end
    if #tasks == 0 then
        body[#body + 1] = Text.line("body", _("当前没有后台任务"), { width = self.inner, color = self.theme.color.muted })
    end
    if pages > 1 then
        -- 末页不满也补成整页高，翻页时面板和翻页条不跳位置。
        body[#body + 1] = VerticalSpan:new{ width = (first + self.per_page - last) * self.pitch }
        body[#body + 1] = Pager.widget({
            width = self.inner,
            page = self.page,
            pages = pages,
            on_prev = function() self:goPage(self.page - 1) end,
            on_next = function() self:goPage(self.page + 1) end,
        })
    end
    self:setDialog{ title = _("后台任务"), body = body }
end

--- 重画；高度不变时只刷面板区域（任务进度每秒数次，默认 "fast" 免得墨水屏一直闪），
--- 面板变矮时连底下窗口一起重画，免得旧面板残留在遮罩外。
---@param mode string|nil 高度不变时的刷新方式
function TaskDialog:refresh(mode)
    local old = self[1].dimen and self[1].dimen:copy()
    local old_h = self[1]:getSize().h
    self:rebuild()
    local new_h = self[1]:getSize().h
    if new_h == old_h then
        UIManager:setDirty(self, function() return mode or "fast", old end)
    else
        UIManager:setDirty(new_h < old_h and "all" or self, "ui")
    end
end

---@param page integer
function TaskDialog:goPage(page)
    self.page = page
    self:refresh("ui")
end

---@param _arg any
---@param ges table
---@return boolean
function TaskDialog:onSwipeTasks(_arg, ges)
    local dir = BD.flipDirectionIfMirroredUILayout(ges.direction)
    if dir == "west" then
        self:goPage(self.page + 1)
    elseif dir == "east" then
        self:goPage(self.page - 1)
    else
        return false
    end
    return true
end

---@param task { key: string, title: string|nil }
function TaskDialog.confirmCancel(task)
    Confirm:new{
        text = T(_("取消任务「%1」？"), task.title or ""),
        ok_text = _("取消任务"),
        cancel_text = _("继续"),
        ok_callback = function()
            local live = Tasks.get(task.key)
            if live then live.cancel() end
        end,
    }:show()
end

function TaskDialog:onCloseWidget()
    self.watch.cancel()
    Modal.onCloseWidget(self)
end

return TaskDialog
