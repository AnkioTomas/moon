--[[--
    KOReader  Lifecycle 基类

    用于定义统一的生命周期和事件入口。

    生命周期用于描述所处的阶段：
        onCreate()   → 创建
        onStart()    → 启动
        onResume()   → 恢复并开始工作
        onPause()    → 暂停工作
        onStop()     → 停止工作
        onDestroy()  → 销毁

    事件用于描述运行过程中发生的具体事件：
        onEvent(event)

    生命周期和事件是两个独立的机制：

        生命周期：
            描述「现在处于什么阶段」

        事件：
            描述「现在发生了什么事情」

    继承：Subclass:new()；组合：Lifecycle.attach(owner)。
    dispatch("Create") 等负责记录 state 并调用对应阶段，不自动补调其他阶段。
    new/attach 绑定后的 onXxx 直接调用也记录状态，但不校验转换顺序。
    阶段处理函数应在 new/attach 前定义，不在绑定后替换。
    @module koplugin.book.ui.lifecycle
--]]

---@alias LifecycleState 'new'|'Create'|'Start'|'Resume'|'Pause'|'Stop'|'Destroy'
---@alias LifecycleStage 'Create'|'Start'|'Resume'|'Pause'|'Stop'|'Destroy'
---@class Lifecycle
---@field state LifecycleState 当前进入的阶段，处理异常不会回滚状态
---@field owner? table 组合模式的处理对象，其业务状态保持独立
local Lifecycle = {}

Lifecycle.__index = Lifecycle

--- 实例级绑定，捕获子类覆写；不修改类或其他实例。
---@param lifecycle Lifecycle
---@param owner table
local function bind(lifecycle, owner)
    for _, stage in ipairs({ "Create", "Start", "Resume", "Pause", "Stop", "Destroy" }) do
        local name = "on" .. stage
        local handler = owner[name]
        owner[name] = function(self, ...)
            lifecycle.state = stage
            if handler then return handler(self, ...) end
        end
    end
end


--- 创建一个 Lifecycle 实例。
---
--- 子类可以通过继承 Lifecycle，并调用 new() 创建实例。
---
---@return Lifecycle
function Lifecycle:new()
    local instance = setmetatable({ state = "new" }, self)
    bind(instance, instance)
    return instance
end

--- 为已有父类的控件创建独立生命周期对象。
---@param owner table
---@return Lifecycle
function Lifecycle.attach(owner)
    local lifecycle = setmetatable({ owner = owner, state = "new" }, Lifecycle)
    bind(lifecycle, owner)
    return lifecycle
end

--- 仅 Resume 阶段允许修改 UI；不判断控件存在性或窗口遮挡。
---@return boolean
function Lifecycle:uiReady()
    return self.state == "Resume"
end

--- 是否处于活跃状态；Pause、Stop、Destroy 返回 false。
---@return boolean
function Lifecycle:Alive()
    return self.state == "new" or self.state == "Create"
        or self.state == "Start" or self.state == "Resume"
end



--- 按名称分发，不限制调用顺序；每次调用都执行对应方法，异常原样传播。
---@param event LifecycleStage
---@param ... any 阶段处理参数
---@return any ... 阶段处理函数的返回值
function Lifecycle:dispatch(event, ...)
    self.state = event
    local owner = self.owner or self
    local handler = owner["on" .. event]
    if handler then return handler(owner, ...) end
end


----------------------------------------------------------------------
-- 生命周期
----------------------------------------------------------------------

--- 创建。
---
--- 在实例创建并完成基础初始化时调用。
---
--- 适合进行：
---   - 初始化内部状态
---   - 创建数据结构
---   - 初始化配置
---   - 创建需要长期使用的对象
---
--- 此阶段通常只执行一次。
function Lifecycle:onCreate()
end


--- 启动。
---
--- 在完成创建后调用，用于让开始参与 KOReader 的运行环境。
---
--- 适合进行：
---   - 注册事件监听
---   - 注册菜单
---   - 注册 UI 操作
---   - 初始化后台任务
---
--- 与 onCreate() 的区别：
---   onCreate() 更适合进行对象自身的初始化；
---   onStart() 更适合与 KOReader 运行环境建立关联。
function Lifecycle:onStart()
end


--- 恢复工作。
---
--- 表示进入活跃状态，可以正常执行工作。
---
--- 适合进行：
---   - 恢复暂停的任务
---   - 开始监听特定事件
---   - 恢复定时任务
---   - 恢复临时资源
---
--- 从暂停状态恢复时也可以再次调用。
function Lifecycle:onResume()
end


--- 暂停工作。
---
--- 表示暂时不应该继续执行活跃任务，但本身仍然存在。
---
--- 适合进行：
---   - 暂停后台任务
---   - 暂停定时器
---   - 暂停 UI 更新
---   - 暂停不必要的资源消耗
---
--- 暂停后仍然可以通过 onResume() 恢复工作。
function Lifecycle:onPause()
end


--- 停止。
---
--- 表示当前不再参与正常工作。
---
--- 适合进行：
---   - 停止后台任务
---   - 移除临时监听
---   - 释放暂时占用的资源
---
--- 与 onDestroy() 的区别：
---   onStop() 表示「暂时停止工作」；
---   onDestroy() 表示「生命周期结束」。
function Lifecycle:onStop()
end


--- 销毁。
---
--- 表示生命周期结束。
---
--- 适合进行：
---   - 释放所有资源
---   - 移除事件监听
---   - 取消后台任务
---   - 清理缓存
---   - 清理内部状态
---
--- 调用此方法后，实例通常不再继续使用。
function Lifecycle:onDestroy()
end


----------------------------------------------------------------------
-- 事件
----------------------------------------------------------------------

--- 处理事件。
---
--- KOReader 或框架发生事件时，通过此方法通知。
---
--- 生命周期描述所处的阶段，而事件描述运行过程中
--- 发生的具体事情。
---
--- 例如：
---   onEvent("BookOpened")
---   onEvent("BookClosed")
---   onEvent("PageUpdate")
---   onEvent("ReaderReady")
---
--- 具体可以重写此方法，根据 event 类型进行处理。
---
--- @param event string|table 事件对象或事件名称
function Lifecycle:onEvent(event)
end


return Lifecycle
