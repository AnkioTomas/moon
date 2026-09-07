--[[
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

    具体可以继承 Lifecycle，并按需重写生命周期
    或事件处理方法。
--]]

local Lifecycle = {}

Lifecycle.__index = Lifecycle


--- 创建一个 Lifecycle 实例。
---
--- 子类可以通过继承 Lifecycle，并调用 new() 创建实例。
---
--- @return table Lifecycle 实例
function Lifecycle:new()
    return setmetatable({}, self)
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
