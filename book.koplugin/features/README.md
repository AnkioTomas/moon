# features

可插拔功能的统一生命周期入口。`main.lua` 不再逐个 `require` 再初始化，只在各生命周期调一行：

```lua
Features.emit("onCreate", self)
```

`features/init.lua` 按 `list` 顺序加载每个 feature，调用对应钩子。

## 目录约定

```text
features/
├── init.lua        -- 登记表 + 分发
├── README.md
└── <name>/
    └── init.lua    -- feature 入口，导出钩子
```

每个 feature 一个目录，入口固定为 `init.lua`，模块名为 `features.<name>`。
KOReader 只把 `plugin_root/?.lua` 加进 `package.path`，不会解析 `?/init.lua`，所以 `.init` 不能省。
feature 内部的其它文件用完整模块名引用，例如 `require("features.<name>.ui")`。

## 钩子

钩子是 feature 模块上的普通函数（点号定义，不是方法），全部可选，用不到就不写。
参数只有插件实例 `plugin`（`BookPlugin`）。

| 钩子 | 时机 | main.lua 位置 |
|---|---|---|
| `onCreate(plugin)` | 插件实例初始化 | `BookPlugin:init` |
| `onSuspend(plugin)` | 设备休眠前 | `BookPlugin:onSuspend` |
| `onResume(plugin)` | 设备唤醒后 | `BookPlugin:onResume` |
| `onExit(plugin)` | KOReader 退出 | `BookPlugin:onExit` |

钩子名就是 KOReader 事件名（`onCreate` 除外），main.lua 同名转发，不另起别名。

需要的上下文自己从 `plugin` 取：`plugin.ui`（FileManager 或 ReaderUI）、`plugin.path`（插件根目录）、
`plugin.ui.document`（有值 = 阅读器侧）。别用 `plugin.desktop` 分侧：那是桌面窗口，文件管理器侧也常为 nil。

KOReader 事件（Dispatcher 动作、广播）写进模块的 `events` 表，键是不带 `on` 的事件名，
值是 `fn(plugin, ...)`，`...` 为事件原参数；返回 true 即已处理。不要往插件实例上挂 `onXxx` 方法。

## 必须知道的行为

- **onCreate 会被调用多次。** KOReader 为 FileManager 和 Reader 各建一个插件实例，每次开书、关书都会重新 `init`。
  monkey-patch KOReader 的 feature 必须自己防重入（模块级标记，见下方示例）。
- **顺序即 `list` 顺序。** 不扫目录，不按字母排序。两个 feature patch 同一个 KOReader 方法时，谁先谁后由这里决定。
- **异常不吞。** 钩子抛错直接上抛，和在 `main.lua` 里手写调用的语义一致。不要在分发层加 `pcall`。
- **只有登记的才加载。** 目录存在但没写进 `list` 的 feature 不会被加载。

## 新增 feature

1. 复制 `tpl/` 为 `<name>/`，删掉用不到的钩子。
2. 在 `features/init.lua` 的 `list` 里按需要的位置加入 `"<name>"`。
3. 测试放在 `tests/features/<name>/`，与本目录镜像。

最小示例：

```lua
--[[--
一句话说明这个 feature。

@module koplugin.book.features.example
--]]

local Example = {}
local installed = false

---@param plugin BookPlugin
function Example.onCreate(plugin)
    if installed then return end
    installed = true
    -- patch KOReader / 注册菜单 / 启动服务
end

return Example
```

## 从旧写法迁移

对 `main.lua` 里现有的 `require("xxx").onCreate()` 模块，一次迁一个：

1. 把目录移到 `features/<name>/`，全仓库改 require 路径（统一点号风格，斜杠和点号会注册成两个模块实例）。
2. 签名统一为 `onCreate(plugin)`：原来接 `self.ui` 的改取 `plugin.ui`，接 `{ plugin_root = self.path }` 的改取 `plugin.path`。
3. 删掉 `main.lua` 里它在各生命周期的手工调用，按原来的调用顺序加入 `list`。
4. 现有钩子覆盖不到的事件（如 `onFrontlightChanged`、网络恢复），迁到它时再在 `features/init.lua` 约定并在 `main.lua` 接一行，不提前加。

## 不属于这里

阅读会话（`reader/session`）、后台任务（`workers/tasks`）、源生命周期（`SourceBase:onCreate` / `onNetworkConnected` 等，main 转发）
是核心编排：有返回值、有调用顺序约束，或需要额外参数，继续在 `main.lua` 里显式调用。

## 模板

`tpl/` 是示范 feature，四个钩子只打 debug 日志，目前登记在 `list` 里用于验证链路。
迁移第一个真实 feature 时把它从 `list` 移除即可。
