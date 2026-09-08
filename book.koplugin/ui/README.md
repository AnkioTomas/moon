# UI 生命周期

统一实现在 [`lifecycle.lua`](lifecycle.lua)，支持普通组件继承，也支持已有 KOReader 父类的控件通过组合使用。

## 阶段与状态

`state` 初始为 `"new"`。进入阶段处理函数之前记录新状态；处理函数抛错时异常原样传播，状态不回滚。

| 方法 | state | 职责 |
| --- | --- | --- |
| `onCreate()` | `Create` | 初始化组件资源 |
| `onStart()` | `Start` | 注册监听、启动运行所需资源 |
| `onResume()` | `Resume` | 恢复可见组件的工作和 UI 更新 |
| `onPause()` | `Pause` | 暂停任务，保留可恢复状态 |
| `onStop()` | `Stop` | 停止运行资源、移除监听 |
| `onDestroy()` | `Destroy` | 释放资源和控件引用 |

各阶段职责独立，**禁止生命周期方法互相调用或互设别名**。调用顺序由拥有者编排，Lifecycle 不校验转换顺序、不自动补调阶段，也不跳过重复调用。组件应避免重复注册监听、重复调度或重复释放资源。

业务事件 `onEvent(event, payload)` 不改变生命周期状态，不能通过 `dispatch()` 分发业务事件。

## 继承

```lua
local Lifecycle = require("ui.lifecycle")
local Component = setmetatable({}, Lifecycle)
Component.__index = Component

function Component:onResume()
    -- 此时 self.state == "Resume"。
end

local component = Component:new()
component:onCreate()
component:onStart()
component:onResume()
assert(component:uiAvailable())
```

`Lifecycle:new()` 在实例上绑定六个阶段方法，因此子类覆写的方法也会记录状态。处理方法必须在构造前定义，绑定后不要重新赋值覆盖这些方法。

自定义构造函数需要调用 `Lifecycle.new(self)`，再补充业务字段；仅用 `setmetatable({}, self)` 不会执行绑定。继承模式的 `state` 保留给生命周期，不能再用作页面数据字段。

## 组合

Desktop 等控件保留 `InputContainer:extend{}` 的继承链，通过 `attach` 接入：

```lua
local Lifecycle = require("ui.lifecycle")
local InputContainer = require("ui/widget/container/inputcontainer")
local Desktop = InputContainer:extend{}

function Desktop:init()
    self.lifecycle = Lifecycle.attach(self)
end

function Desktop:onResume()
    -- self.lifecycle.state == "Resume"。
    -- 向当前可见的子组件传递 Resume。
end
```

每个对象只 attach 一次。直接调用 `desktop:onResume()` 或调用 `desktop.lifecycle:dispatch("Resume")` 都会更新 `desktop.lifecycle.state`；原对象自己的业务 `state` 不受影响。

## 分发与 UI 更新

`dispatch(stage, ...)` 接受表中六个阶段名，记录状态并调用对应的 `onXxx(...)`；参数和返回值原样传递。它与直接调用绑定后的阶段方法一样，每次都会执行处理函数。

`uiAvailable()` 仅在 `state == "Resume"` 时返回 `true`。继承模式调用 `component:uiAvailable()`；组合模式调用 `desktop.lifecycle:uiAvailable()`。

它用于判断异步回调能否提交 UI 更新，不保证控件存在，也不判断窗口遮挡、请求是否过期或数据是否属于当前源。任务取消和旧回调的身份校验仍由任务拥有者负责。

## 父子组件约定

- 父组件显式传递对应阶段；Lifecycle 不会自动遍历子组件。
- Desktop 生命周期覆盖 Home 和 TopBar，再由它们传递给子组件。
- 切离 Home TAB 时暂停 Home，切回时恢复；TopBar 始终显示，不随 TAB 切换暂停。
- 恢复只针对当前显示的子组件；禁用或布局放不下的组件不能继续更新旧控件。
- `build()` / `content()` 不触发生命周期。重建时释放旧视图引用与组件销毁是不同操作。
- 生命周期状态由 Lifecycle 记录；页码、请求句柄、控件引用等业务状态归各组件所有。

## 接入边界与验证

继承链上存在 Lifecycle 不代表已经启用自动记录。现有自定义构造函数若绕过 `Lifecycle.new` 且没有调用 `attach`，其直接 `onXxx()` 调用仍不记录状态。迁移时应逐一检查，不能直接把旧组件的业务 `state` 替换成生命周期状态。

离线验证：

```sh
./tests/run.sh tests/ui/lifecycle_spec.lua
```

测试覆盖继承、组合、直接调用、重复分发、任意阶段顺序、UI 可用性、参数与返回值以及异常传播。
