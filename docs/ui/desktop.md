# ui.desktop — 月读桌面

代码：[`ui/desktop.lua`](../../book.koplugin/ui/desktop.lua) + `ui/desktop/*.lua`。

## 设计

全屏壳只负责顶栏、内容槽、底栏和手势；页面内容在子模块。保留 `InputContainer:extend`，经 `Lifecycle.attach` 管阶段。

```text
┌────────────────────────────────────────────┐
│ 时间 · 当前源          设备状态指标         │ TopBar
├────────────────────────────────────────────┤
│           当前 Tab 内容（顶对齐）            │
├────────────────────────────────────────────┤
│ 首页  图书馆  [Z站]   [统计]  设置          │ 动态底栏
└────────────────────────────────────────────┘
```

- 首页 / 图书馆 / 设置：始终存在
- Z站：由 Z-Library 开关（`zlibEnabled()`）决定；统计：由当前源能力 `insight` 决定（不要页面自己伪造 Tab）
- 页内溢出用 `Pager`；桌面页不用全屏 `ScrollableContainer`
- 加载/空态/错误占位几何尽量稳定，避免底栏跳动

`Desktop:onEvent` **只广播**。换源先改 `desktop.source` 再广播。详情走 `Detail.open`，设置子页走 `Settings:open(id)`，不要经 Desktop 做业务分流。

### 插件更新

`Desktop:onResume` 调 `update.autoCheck`（网络请求）；不在插件 init / `onNetworkConnected` 里抢跑。
KOReader 宿主版本门槛在 `ko_version`，与桌面无关。

---

## 用法

### 打开与生命周期

```lua
-- plugin.openDesktop → 创建/显示 Desktop
desktop:onResume()   -- 显示
desktop:onPause()    -- 休眠或被遮挡
desktop:onDestroy()  -- 关闭
```

切 Tab：Pause 离开的页，Resume 进入的页；TopBar 不 Pause。

### 换源

```lua
desktop.source = Registry.setActive(id)  -- 或先 setActive 再赋引用
desktop:onEvent("source_changed")
-- 各页自行丢弃旧请求、按新源重拉本地 catalog
```

### 首页组件

数据：`home.home_widgets` = `{ id, page, order, height }`。  
`height`：`default`（内容高）/ `fill`（吃剩余）/ 自定义像素。

```text
新增组件：
  1. ui/desktop/home/views/foo.lua
  2. home/registry.lua 注册一行
  3. 可复用画面放 ui/components/，组件只做 Lifecycle + 拉数 + 高度预算
```

长按进入编辑态（删/移/调高）；PageStrip「完成」保存。左右滑翻页；编辑态禁用左右滑。

### 同步刷新

```lua
-- 源 sync 完成后
desktop:onEvent("home_refresh", "shelf_sync")
-- 回调里必须：
if desktop.lifecycle.state == "Destroy" then return end
if desktop.source.id ~= expected then return end
```

### 注意

- 图书馆/Z站可左右滑翻页；其它页不要绑无语义的左右滑。
- 数据源不支持的能力：隐藏入口，不要放「点了才说不支持」的按钮。
