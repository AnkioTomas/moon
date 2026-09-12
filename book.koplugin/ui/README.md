# BaseView

`ui.baseview` 统一根骨架、具名区域、资源所有权和离屏 PNG 输出。生命周期沿用 `ui.lifecycle`，不增加阶段或转换规则。普通视图继承 BaseView；已有 KOReader 父类的 Desktop 保留 `InputContainer:extend`，通过 `BaseView.attach(desktop)` 管理槽位。

## 构建与更新

- `View:new(opts)` 创建实例，`self.lifecycle.state` 保存生命周期，业务 `state` 不受影响。
- `createWidget()` 生成内容 Widget；`build()` 创建一次独立根容器，后续返回同一根。
- 根容器负责视图生命周期，内部 TextWidget 的 `free()` 仍可用于文字缓存失效，不会销毁视图。
- `updateView(data)` 由组件原地改字或更新具名区域；需要重建内容时调用 `rebuild()`，根容器不变。
- `registerRegion(name, container, index, rect)` 登记槽位，`rect` 是绝对矩形或返回它的函数。`replaceRegion(name, child)` 释放旧内容，重置容器布局，并刷新新旧矩形并集。
- 改字后调用 `dirty(name)`。只有设置了 `host` 且处于 Resume 阶段才刷新屏幕；默认 `content` 区域使用根容器实际绘制坐标。
- 大小变化影响兄弟布局时重建最近的布局父区域。顶栏文字宽度变化会重排整条顶栏。

## 所有权与生命周期

`self.children` 存放父视图拥有的子视图。内容重排时，新树复用的子树以及仍由父视图拥有的隐藏子视图会从旧树摘除，再释放旧容器；翻页不会误销毁隐藏组件。父视图 Destroy 时释放全部孩子与自己的根。

父视图显式传递 Create/Start/Resume/Pause/Stop。显示在不同 Tab 的页面由 Desktop 持有，切页保留其根，关窗再销毁。临时替换内容默认由 `replaceRegion` 释放；只有外部拥有者继续持有旧页时使用第三参数 `keep_old=true`。

HTTP/Job 仍登记到 `view.lifecycle:addHttp` / `addJob`。定时器与订阅由组件在 Resume 启动，在 Pause/Stop/Destroy 清理。BaseView 不自动调用 Resume，也不改变 Lifecycle 的重复调用语义。

## 一次性加载与出图

动态视图实现 `loadData(done)`，通过 `done(data, err)` 交付数据，返回现有 `{ cancel }` 句柄。`load(cb)` 取消本实例前一轮加载，拒绝晚到结果，完成后从 Lifecycle 的在飞表移除句柄。不要在原始异步回调里直接改视图状态。

默认 `onStart(cb)` 调用一次性加载。覆写此阶段的复合视图必须等孩子完成后调用传入的 `cb(ok, err)`。业务网络拉取与周期调度不放入 `createWidget`。现有 `Image.widget` 的图片准备仍由图片组件发起，`Image.await(root, cb)` 按明确的 Widget 树等待全部图片落定；没有模块级构建批次。

```lua
local Home = require("ui.desktop.home")
local Paths = require("utils.paths")
Paths.ensureScreensaverDir()
local job = Home:renderToImage({
    path = Paths.screensaverDir() .. "/home.png",
    width = 600,
    height = 800,
    source = source,
}, function(ok, err, path)
    -- 成功时 path 是完整 PNG；失败时旧文件保留。
end)
-- 不再需要本次结果时：job:cancel()
```

`renderToImage` 创建独立实例，执行 Create/Start，等待数据和图片，再用指定像素尺寸绘制 PNG，最后 Stop/Destroy；不进入 Resume。取消不回调，其余结果只回调一次。省略尺寸时使用锁屏竖屏尺寸，输出目录由调用者准备。已有缓存/占位回退由具体组件决定。

`ui.render` 借用 Widget 完成绘制及 PNG 原子写入，不销毁视图；BaseView 拥有并释放导出实例。旧 `lockscreen.render.write` 继续消费锁屏 blocks 中的临时 Widget。不要将正在显示的实例交给锁屏 blocks 消费。

## 当前迁移范围

已接入：Desktop 具名槽位、Home 及首页组件、TopBar 及状态项、BottomBar、Settings、Quote、Surface。`Quote` 使用 `Quote:new{ data = quote, width = w, height = h }:build()`；Surface 使用 `Surface:new{ child = widget, kind = "card"或"pill", options = opts }:build()`；BottomBar 使用 `data = { tabs, active, on_tab }`。

尚未迁移到统一 BaseView 契约：图书馆、书城、统计与详情页面，其他展示构建器、原生菜单/阅读扩展，以及仍使用 blocks 的锁屏主体。它们继续使用现有接口，不能假设它们已经支持 `renderToImage`。`lockscreen.compose` 已改用独立的图片等待与共享 PNG 渲染能力，未增加设置选项。

以下为 Lifecycle 自身的接口说明，仍供未迁移组件使用。

# UI 生命周期

统一实现在 [`lifecycle.lua`](lifecycle.lua)，支持普通组件继承，也支持已有 KOReader 父类的控件通过组合使用。

## 阶段与状态

`state` 初始为 `"new"`。进入阶段处理函数之前记录新状态；处理函数抛错时异常原样传播，状态不回滚。

| 方法 | state | 职责 |
| --- | --- | --- |
| `onCreate()` | `Create` | 初始化组件资源 |
| `onStart()` | `Start` | 注册监听、启动运行所需资源 |
| `onResume()` | `Resume` | 恢复可见组件的工作和 UI 更新（显示入口） |
| `onPause()` | `Pause` | 暂停任务，保留可恢复状态 |
| `onStop()` | `Stop` | 停止运行资源、移除监听 |
| `onDestroy()` | `Destroy` | 释放资源和控件引用（销毁入口） |

**显示 / 销毁会按当前 `state` 补中间阶段**，其余阶段仍单步进入：

- `onResume()`：`new` → Create+Start；`Create`/`Stop` → Start；已 `Resume` 仍执行一次；已 `Destroy` 报错。
- `onDestroy()`：`Resume` → Pause+Stop；`Pause`/`Create`/`Start` → Stop；已 `Destroy` 为无操作。

补全过程只把参数传给最终目标阶段；中间阶段无参调用（例如显示补到的 `onStart()` 不带 `cb`）。拥有者仍可显式单步调用 `onPause` / `onStop`（如 Tab 切离只暂停）。

各阶段职责独立，**禁止业务处理函数互相调用或互设别名**；补全由 Lifecycle 绑定层完成。组件应避免重复注册监听、重复调度或重复释放资源。

业务事件 `onEvent(event, payload)` 不改变生命周期状态，不能通过 `dispatch()` 分发业务事件。Desktop:onEvent 只广播；换源先改自己的 source/tab。详情走 `Detail.open`，设置子页走 `Settings:showSub`，不要再经 Desktop 分流。

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
assert(component:uiReady())
```

`Lifecycle:new()` 在实例上绑定六个阶段方法，因此子类覆写的方法也会记录状态。处理方法必须在构造前定义，绑定后不要重新赋值覆盖这些方法。

子类直接 `Class:new()`，走继承来的构造；不要再写一遍 `Lifecycle.new`。业务字段用的时候再赋值。仅用 `setmetatable({}, self)` 不会执行绑定。继承模式的 `state` 保留给生命周期，不能再用作页面数据字段。

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

`dispatch(stage, ...)` 接受表中六个阶段名，调用绑定后的 `onXxx(...)`；Resume / Destroy 走补全语义，参数只交给最终阶段。Create / Start / Pause / Stop 每次调用都会执行处理函数。

`uiReady()` 仅在 `state == "Resume"` 时返回 `true`。继承模式调用 `component:uiReady()`；组合模式调用 `desktop.lifecycle:uiReady()`。

它用于判断异步回调能否提交 UI 更新，不保证控件存在，也不判断窗口遮挡、请求是否过期或数据是否属于当前源。任务取消和旧回调的身份校验仍由任务拥有者负责。

`Alive()` 判断是否处于活跃状态：`new`、`Create`、`Start`、`Resume` 返回 true，`Pause`、`Stop`、`Destroy` 返回 false。不记录历史，不增加状态字段。

## jobs / http

每个 Lifecycle 实例（`new` / `attach`）自带 `jobs` 和 `http` 两张表。组件自己的异步句柄入表，不要另挂模块级 `_job`。

| 表 | 登记 | 句柄 |
| --- | --- | --- |
| `jobs` | `self:addJob(job)` | `Job.run` 返回值，`:cancel()` |
| `http` | `self:addHttp(handle)` | HTTP / 源异步的 `{ cancel }` |

组合模式把句柄登记到该对象自己的 `lifecycle:addHttp` / `addJob`，不要塞进 Desktop。Desktop 只转发阶段，各子组件 Pause 时取消自己的表。

进入 `Pause` / `Stop` / `Destroy` 时 bind 先 `abortWork()` 取消两张表，再调用组件自己的 `onPause` 等。未走 `Lifecycle.new` / `attach` 的旧实例必须在自己的 `onPause` 里调用 `self:abortWork()`。

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
