--[[--
Desktop 生命周期：Create / Resume / Pause / Destroy。
归属 Desktop 渲染树；全屏浮层（如详情）自行 Lifecycle.attach。组合：Lifecycle.attach(owner)。
@module koplugin.book.ui.lifecycle
--]]

---@alias LifecycleState 'new'|'Create'|'Resume'|'Pause'|'Destroy'
---@alias LifecycleStage 'Create'|'Resume'|'Pause'|'Destroy'

--- 可挂 Lifecycle 的宿主：须具备四阶段方法（可空实现；bind 会包装）。
---@class LifecycleOwner
---@field name string|nil
---@field id string|nil
---@field lifecycle Lifecycle|nil
---@field onCreate fun(self: LifecycleOwner, ...: any): any
---@field onResume fun(self: LifecycleOwner, ...: any): any
---@field onPause fun(self: LifecycleOwner, ...: any): any
---@field onDestroy fun(self: LifecycleOwner, ...: any): any

---@class Lifecycle : LifecycleOwner
---@field state LifecycleState 当前进入的阶段，处理异常不会回滚状态
---@field owner? LifecycleOwner 组合模式的处理对象，其业务状态保持独立
---@field http CancelHandle[] HTTP / 源异步返回的 { cancel }
local Lifecycle = {}

Lifecycle.__index = Lifecycle

local logger = require("utils.log")

local ABORT_STAGES = { Pause = true, Destroy = true }

-- 补齐进入目标阶段所必需的边界阶段，保证生命周期顺序连续。
---@param lifecycle Lifecycle
---@param owner LifecycleOwner
---@param stage LifecycleStage
---@return boolean
local function completeBefore(lifecycle, owner, stage)
    local state = lifecycle.state
    if stage == "Resume" then
        if state == "Destroy" then error("cannot resume destroyed lifecycle", 0) end
        if state == "new" then owner:onCreate() end
    elseif stage == "Destroy" then
        if state == "Destroy" then return false end
        if state == "Resume" then owner:onPause() end
    end
    return true
end

--- 日志主体名：name / id，否则退回 tostring。
---@param owner LifecycleOwner|table
---@return string
local function subject(owner)
    local tag = owner.name or owner.id
    if type(tag) == "string" and tag ~= "" then
        return tag
    end
    return tostring(owner)
end

--- 取消单个句柄；cancel 失败不能阻断其它句柄的取消。
---@param handle table|nil
local function cancelOne(handle)
    if type(handle) ~= "table" then return end
    local cancel = handle.cancel
    if type(cancel) == "function" then
        pcall(cancel, handle)
    end
end

--- 取消并清空 http。Pause 由 bind 先调；未走 bind 的实例自己调。
function Lifecycle:abortWork()
    local http = self.http
    self.http = {}
    if http then
        for i = 1, #http do
            cancelOne(http[i])
        end
    end
end

--- 登记 HTTP / 源异步句柄。Pause / Destroy 时取消。
---@param handle CancelHandle|table|nil
---@return CancelHandle|table|nil
function Lifecycle:addHttp(handle)
    if type(handle) ~= "table" then return handle end
    local http = self.http
    if not http then
        http = {}
        self.http = http
    end
    http[#http + 1] = handle
    return handle
end

--- 实例级绑定，捕获子类覆写；不修改类或其他实例。
--- 每次阶段入口打 DEBUG 日志（受 book_debug_enabled 控制；无 logger 时静默）。
---@param lifecycle Lifecycle
---@param owner LifecycleOwner
local function bind(lifecycle, owner)
    for _, stage in ipairs({ "Create", "Resume", "Pause", "Destroy" }) do
        local name = "on" .. stage
        local handler = owner[name]
        local wrapped = function(self, ...)
            if not completeBefore(lifecycle, self, stage) then return end
            local prev = lifecycle.state
            lifecycle.state = stage
            logger.dbg("moon.lifecycle", subject(self), prev, "->", stage)
            if ABORT_STAGES[stage] then
                lifecycle:abortWork()
            end
            if handler then return handler(self, ...) end
        end
        owner[name] = wrapped
    end
end


--- 创建一个 Lifecycle 实例。
---
--- 子类：`Subclass:new()` 或 `Subclass:new({ field = value })`。
--- init 可选；拷贝字段到新表，不改写调用方。state / http 始终由框架写入。
---
---@generic T : Lifecycle
---@param self T
---@param init table|nil
---@return T
function Lifecycle:new(init)
    local instance = {}
    if type(init) == "table" then
        for k, v in pairs(init) do
            instance[k] = v
        end
    end
    instance.state = "new"
    instance.http = {}
    setmetatable(instance, self)
    bind(instance, instance)
    return instance
end

--- 为已有父类的控件创建独立生命周期对象。
---@param owner LifecycleOwner
---@return Lifecycle
function Lifecycle.attach(owner)
    local lifecycle = setmetatable({ owner = owner, state = "new", http = {} }, Lifecycle)
    bind(lifecycle, owner)
    return lifecycle
end

--- 仅 Resume 阶段允许修改 UI；不判断控件存在性或窗口遮挡。
---@return boolean
function Lifecycle:uiReady()
    return self.state == "Resume"
end

function Lifecycle:onCreate()
end

function Lifecycle:onResume()
end

--- Pause / Destroy 前 bind 会 abortWork()。
function Lifecycle:onPause()
end

function Lifecycle:onDestroy()
end

---@param event string|table
function Lifecycle:onEvent(event)
end


return Lifecycle
