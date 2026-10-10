# plugin — KOReader 接线

入口：[`main.lua`](../../book.koplugin/main.lua)。

## 设计

KOReader 为 FileManager 与 Reader **各创建一个**插件实例。Reader 实例只服务当前文档；关书后桌面由 FM 实例承载。本层是事件接线板，不写业务规则。

初始化分工：

```text
BookPlugin:init
├── ko_version.check（KOReader 本地门槛；不满足则 return）
├── logger / Turbo（须在 UIManager:run 前由别处启用）
├── Fonts.onCreate（= applyCurrent，按配置应用 UI 字体）
├── Menu.onCreate（menu.lua：主菜单 / 设置置顶 / 启动项菜单 / book_open_shelf 手势 / start_with 种入）
├── 当前源 onCreate → Online.onNetworkConnected → Features.emit("onCreate")（面板 / 锁屏 / 远程 / IME 等都是 feature）
└── nextTick Desktop.autoOpen（兜底；正常由 onShow = Desktop.autoOpen 同步接管）
更新检查在 Desktop:onResume → Update.autoCheck
```

宿主接线只管 KOReader 外壳（菜单、「打开月读」手势、启动项），不管锁屏/远程/IME。feature 自己的手势和 KOReader 事件处理函数在各自 `onCreate` 里登记并挂到插件实例上（KOReader 按 handler 名在实例上查找）：`xray` → `book_xray_refresh`/`onBookXrayRefresh`，`sidebar` → `book_reader_sidebar`/`onBookReaderSidebar`，`nightmode` → `onFrontlightStateChanged`。

插件增强模块统一 Desktop 生命周期名：`onCreate` / `onPause` / `onResume` / `onDestroy`。  
KOReader 宿主事件仍叫 `onSuspend` / `onExit`（契约），内部再转发到上述名字。

### 启动项与自动开桌面

启动项读写只走 `menu` 的 `openOnStart()` / `setOpenOnStart(on)`，别处不要直接读写 `start_with`，也不要硬编码 `bookshelf_book`。

`want_auto_open`（desktop/init.lua 模块级，由 `Desktop.autoOpen` 读写）：

| 值 | 含义 |
|---|---|
| `nil` | 还没见过 FileManager（首次在 FM 实例上调用时读启动项） |
| `true` | `start_with == bookshelf_book`，本次就自动开桌面 |
| `false` | 不再自动开 |

首次安装（`common.start_with_seeded` 仍为 false）时，`Menu.onCreate` 会**强制**把 KOReader 的 `start_with` 写成 `bookshelf_book`，不跟系统默认 `filemanager`。只种一次；之后设置里「启动打开桌面」或系统启动项由用户改。

打开桌面只有 `desktop/init.lua` 的 `Desktop.open(plugin)` 一个入口（插件上不再有 `openDesktop` / `openBook` 转发，开书直接 `require("desktop.open").book(plugin, book)`）：若在 Reader 实例上调用，先关文档，再委托 **FM 实例**打开，避免叠层。

### 源生命周期与事件

main 经 `emitSource` 把 init / 休眠 / 唤醒 / 联网 / 退出转给**所有启用源**的 `onCreate` / `onSuspend` / `onResume` / `onNetworkConnected` / `onExit`（参数为插件实例；除 `onNetworkConnected` 只推本源脏行外，`SourceBase` 默认空操作），随后 `Online.onNetworkConnected`（启动时若已联网会刷一次），再 `Features.emit`，每个源 / 接口经 guard 隔离。

业务事件由持有属主源的调用方直接 `source:onEvent(event, payload)`：阅读会话发 `page_changed` / `chapter_changed`（源取 `identity.source`，不回落 current），详情编辑发 `book_meta_changed`。桌面打开 / 换源 / 图书馆刷新的书架与统计同步不走源事件，由 `desktop/sync.lua` 的 `Sync.open` / `Sync.refresh` 直接调源的 `syncBooksAsync` / `syncStatsAsync`。

---

## 用法

```lua
-- 打开书
require("desktop.open").book(self, book)

-- 阅读事件：会话入口与事件同名同参，直接挂到插件上
BookPlugin.onReaderReady = Session.onReaderReady
-- DocSettingsLoad / PageUpdate / PosUpdate / AnnotationsModified / EndOfBook / StartOfBook / CloseDocument 同理

-- 网络恢复：启用源自己推脏，online 补拉离线没刷的，feature 自己刷新。
function BookPlugin:onNetworkConnected()
    emitSource(self, "onNetworkConnected")
    require("online").onNetworkConnected(self)
    require("features").emit("onNetworkConnected", self)
end

-- 旧书事件直接发给属主源
identity.source:onEvent("page_changed", payload)
```

| KOReader 事件 | 处理 |
|---|---|
| `onShow` | `= Desktop.autoOpen`：FM 显示且启动项为月读时开桌面（进程内一次） |
| `onDocSettingsLoad` / `onReaderReady` / 翻页 / 注解 / 章界 / `onCloseDocument` | 直接是 `Session` 的同名函数 |
| `onSuspend` | → 后台任务 / Session `onSuspend`，启用源 / features `onSuspend`（桌面在栈上自收 Suspend） |
| `onResume` | → 各模块 `onResume`（Session / 启用源 / features；桌面在栈上自收 Resume）。online 不跟唤醒 |
| `onExit` | → 启用源 `onExit` / features；桌面在栈上自收 Exit |
| `onNetworkConnected` | 后台任务续跑 + 启用源推本源脏行 + online 补拉 + features（锁屏等）；桌面自收 |

| 源事件 | 含义 |
|---|---|
| `chapter_changed` / `page_changed` | 切章 / 翻页 |
| `book_meta_changed` | 编辑 / 刮削已写库 |
| `book_info_request` | 阅读面板要最新详情 |
