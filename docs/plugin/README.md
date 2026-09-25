# plugin — KOReader 接线

入口：[`main.lua`](../../book.koplugin/main.lua)、[`host.lua`](../../book.koplugin/host.lua)。

## 设计

KOReader 为 FileManager 与 Reader **各创建一个**插件实例。Reader 实例只服务当前文档；关书后桌面由 FM 实例承载。本层是事件接线板，不写业务规则。

初始化分工：

```text
BookPlugin:init
├── ko_version.check（KOReader 本地门槛；不满足则 return）
├── logger / Turbo（须在 UIManager:run 前由别处启用）
├── Host.onCreate   ← 字体图标、主菜单、Dispatcher、start_with 种入
├── translate / baike / dictionary / panel.native  → onCreate
├── lockscreen / remote / ime → onCreate
├── patch.manager.onCreate（内含补丁启动自检）；更新检查在 Desktop:onResume → Update.autoCheck
└── Reader → emitToSource("reader_open")
```

`Host` 不管锁屏/远程/IME。可选增强失败只记日志（如截图分享），不得拖垮阅读主流程。

插件增强模块统一 Desktop 生命周期名：`onCreate` / `onPause` / `onResume` / `onDestroy`。  
KOReader 宿主事件仍叫 `onSuspend` / `onExit`（契约），内部再转发到上述名字。

### Host.want

| 值 | 含义 |
|---|---|
| `nil` | 还没见过 FileManager |
| `true` | `start_with == bookshelf_book`，下次 FM `onShow` 自动开桌面 |
| `false` | 不再自动开 |

首次安装（`common.start_with_seeded` 仍为 false）时，`Host.onCreate` 会**强制**把 KOReader 的 `start_with` 写成 `bookshelf_book`，不跟系统默认 `filemanager`。只种一次；之后设置里「启动打开桌面」或系统启动项由用户改。

`openDesktop`：若在 Reader 实例上调用，先关文档，再委托 **FM 实例**打开，避免叠层。

### 源事件

唯一分发口：`plugin:emitToSource(event, payload, source?)`。第三参指定属主源；省略才用 current。内部 `pcall`，源抛错不挡主流程。

---

## 用法

```lua
-- 打开书
require("book.open").book(self, book)

-- 阅读事件（main 里一行转发）
function BookPlugin:onReaderReady()
    require("ui.reader.session").onReaderReady(self)
end
-- CloseDocument / PageUpdate / Annotations / Suspend / Resume 同理

-- 网络恢复
function BookPlugin:onNetworkConnected()
    require("book.sync").retryDirtyAsync()
    self:emitToSource("network_connected")
    require("lockscreen.init").refresh(nil, true, "network_connected")  -- 强制刷新
end

-- 旧书事件必须带属主源
self:emitToSource("page_changed", payload, identity.source)
```

| KOReader 事件 | 处理 |
|---|---|
| `onShow` | Host：FM 显示且 want→开桌面；`fm_open` |
| `onDocSettingsLoad` | 全书阅读偏好注入 sidecar |
| `onReaderReady` / `onCloseDocument` / 章界 / 翻页 / 注解 | `Session` |
| `onSuspend` | → 各模块 `onPause`（Session / 锁屏 / 远程 / 桌面） |
| `onResume` | → 各模块 `onResume`（桌面在栈上自收 Resume） |
| `onNetworkConnected` | 脏重试 + 源事件 + 锁屏 + 桌面 |
| `onExit` | → 各模块 `onDestroy`（更新 / 远程 / 桌面） |

| 源事件 | 含义 |
|---|---|
| `reader_open` / `fm_open` | 对应实例就绪 |
| `desktop_open` / `desktop_resume` / `home_open` | 桌面可见；基类节流同步 |
| `library_refresh_request` | 用户强制刷新书架 |
| `document_close` / `suspend` | 阅读结清中 |
| `chapter_changed` / `page_changed` | 切章 / 翻页 |
| `book_info_request` | 阅读面板要最新详情 |
| `network_connected` | 网络恢复（基类不推脏） |
