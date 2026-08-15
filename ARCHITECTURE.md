# Book 书库 插件整体流程

> 基于代码实读整理（含 文件:行号 引用），随代码演进可能漂移，以源码为准。

## 核心设计（记住这三条）

1. **一切阅读期逻辑收口在 `ui/reader/session.lua`**，`main.lua` 的每个阅读 handler 都是一行转发。
2. **书籍身份 = `source_id + stable_id`**，`book/store.lua` 是唯一身份门面；磁盘路径是身份的派生物（`md5(stable_id)` 作目录名，见 `utils/paths.lua`）。
3. **所有 SQLite 写走 `utils/db/queue.lua` 串行队列**（防多子进程并发写坏库）；读可主进程直调（WAL 读读安全）。

## 总图

```
KOReader 事件（onReaderReady/onCloseDocument/...）
        │
   main.lua ────────────── 只做两件事：菜单注册 + 一行转发
        │
  ┌─────┴──────┬───────────────┬──────────────┐
ui/desktop 书库UI   ui/reader/session 阅读编排   source/* 数据源
（home/library/     （身份/统计/进度/切章         （moon/wechat/webdav/
 store/insight）     全部收口在这里）              rss/local，统一接口）
        │              │                    │
        └──────┬───────┴────────────────────┘
          book/store.lua 身份门面 + utils/db（5 张表）
```

异步边界只有四类：

- **网络** = Turbo ioloop 回调（`http/request.lua`，一律返回 `{cancel}` job）
- **重 IO / 扫盘** = `utils/task.lua` 子进程（100ms 轮询收结果）
- **SQLite 写** = `utils/db/queue.lua`（主进程 nextTick 串行）
- **UI 编排** = `UIManager:nextTick / scheduleIn`

## 1. 入口与生命周期

- KOReader pluginloader 扫到 `plugins/book.koplugin/`，读 `_meta.lua`（name/fullname），require `main.lua` 返回的 `BookPlugin`（`WidgetContainer:extend`，`main.lua:29-32`）。
- `is_doc_only=false` ⇒ **FileManager 和 Reader 各实例化一份**（`main.lua:4-5`），事件以 `onXxx` 方法分发。
- `BookPlugin:init()`（`main.lua:38`）：
  1. `http.request.ensureTurbo()`（`http/request.lua:156`）——必须在 `UIManager:run()` 前挂上 Turbo ioloop，否则所有网络回调永不被泵；
  2. `Host.attach(self)`（`host.lua:151`）：应用字体/图标 → 注册菜单 → 把设置菜单项插到 setting 首位 → 修补「启动时打开」菜单；
  3. Reader 侧若已有 document，立即 `emitToSource("reader_open")`。
- 三个入口都汇到 `openDesktop()`：
  - 菜单项「Book 桌面」（`main.lua:71 addToMainMenu`）
  - 手势 action `book_open_shelf`（`host.lua:66` → `main.lua:63 onBookOpenShelf`）
  - 开机自启 `start_with == "bookshelf_book"`（`host.lua:175 onShow`）
- 阅读期生命周期（`main.lua:83-130`）：`onReaderReady / onCloseDocument / onEndOfBook / onStartOfBook / onSuspend / onResume / onPageUpdate / onPosUpdate`，全部一行转发到 `ui/reader/session.lua`。
- `emitToSource`（`main.lua:144`）：取 `SourceRegistry.current()`，`pcall(source.onEvent, …)`——源抛错只记日志不阻断主流程。事件清单见 `source/base.lua:63-78` 注释。

## 2. 书库 UI 与数据源

- **源选择**：`source/registry.lua:29-38` FACTORIES（moon/wechat/webdav/rss/local）。活跃源 id 存 `settings/common.lua` 的 `active_source`（默认 `"moon"`）。`Registry.current()`（:146）按 id 懒创建并缓存；`setActive`（:179）= 创建候选 → 写配置 → 原子替换（关旧源）。
- 换源（`ui/desktop/settings.lua:370` → `main.lua:165 onSourceChanged`）：`StatsSync.invalidate()` + `source:clearCaches()` + `desktop:sourceChanged()`（取消在飞 fetch、清各 Tab 缓存）。
- **桌面壳** `ui/desktop.lua` 只做窗体：按 `self.tab` 分发到 `Home / Library / Store / Insight / Settings` 五页。Tab 由源能力决定（`caps.store` → 书城、`caps.insight` → 统计）。
- **书籍列表**：`Library.fetch`（`ui/desktop/library.lua:400`）→ `source:listLibraryAsync({page, page_size, search, ...}, cb)` → 回调校验源代际后 `Store.rememberMany(books)`（写 `books` 表）→ rebuild。契约返回 `{count, data}`。
- **主页**：`Home.fetch` → `source:recentBooksAsync(24, cb)`；首次加载还触发 `book.cache.cleanupStaleAsync`（子进程扫盘清理）。
- **详情**：点封面 → `Desktop:showDetail`（先 `Store.remember(book)`）→ 「开始阅读」→ `plugin:openBook(book)`。
- **书城页**（`ui/desktop/store.lua`）：全局书城走 `zlib/`（非 BookSource）：镜像种子列表 + 故障转移 + 30x 手动跟随（`zlib/client.lua`），下载后经当前源的 `importBookAsync` 导入书库。

## 3. 打开一本书（opens 表的写入点）

`main.lua:158 openBook` → `book/open.lua:206 Open.book`：

1. `Store.refOf(book)` 取身份；`canRead` 检查 `caps.whole_book or caps.chapters`。
2. 按 `caps.chapters` 分叉（`open.lua:222`）：

**整本 epub**（`openWholeBook`，:59）：
- 清残留按章会话 → `Store.remember(book)`。
- 本地源有 `localPathFor` 直接打开（不下载）。
- 缓存命中检查：`Content.isValidBook`（按扩展名验魔数）。
- 未命中：`runWhenOnline` → `Content.sharedJob`（in-flight 合并）→ `source:materializeWholeAsync` 下载（64KB 切片写盘，`.part` + `os.rename` 原子落盘到 `.moon/cache/<source>/book/<md5(stable_id)>/book.<ext>`）。

**按章**（`openChapterBook`，:158）：
- `Chapter.prepareOpenAsync`（`chapters/materialize.lua:200`）：拉详情 → `loadTocAsync` 拉目录（只存内存）→ `getProgressAsync` 定 `start_idx`。
- `Chapter.ensureAsync`：本章 `N.html` 已存在且合法则直返；否则 inflight 去重后 `fetchChapterContentAsync` 拉取，`.part`+rename 原子写。
- `Chapter.bind`（`chapters/session.lua:74`）建按章会话 → `showInitial` → `prefetchAround`（前 1 后 3 章后台下载）。

**两条路都经过 `Store.touchAsync(path, ref)` → `DbQueue.run(OpenDB.upsert)` 写 `opens` 表**——这是「这本书被打开过」的唯一记录点，之后所有身份识别都靠它反查。

## 4. 阅读期编排（ui/reader/session.lua）

`onReaderReady`（:81）固定调用顺序：

1. **身份自举**：按章会话优先（`Chapter.isActive()`），否则 `Store.identityFor(ui.document.file)` 同步查 opens 表。查不到身份的书插件零行为（`_cur = nil`）。
2. `stats.tracker.start(ui)` 开始计时。
3. 章会话时：`patches.enable()` + `wrapReaderUi` + `Chapter.onReaderReady`（落点定位）。
4. `book.progress.pull(ui, source, false)`：先补传积压，再 `getProgressAsync`，差异 >1% 才跳转。
5. 有身份才建 `_cur` 会话快照。
6. `ui.reader.attach(plugin)`：`registerTouchZones` 注入中心点按区 + `registerViewModule("book_bars", bars)` 上下进度条——**仅会话活跃时生效**。
7. `emitToSource("reader_ready")`。

**翻页**（`onPageUpdate/onPosUpdate` → 内部 `onPage`）：`tracker.onPage` → 更新快照（按章模式合成全书比例）→ 进度条重绘 → `emitToSource("page_changed", …)`。

**切章**：章末 `onEndOfBook` 自动下一章；章首再往前翻由 `patches.lua` 的 hook 造 `StartOfBook` 事件。`gotoChapter`：未缓存先下载 → 更新 `s.idx` → `touchAsync` 刷新 opens（path 指向最新章）→ `switchDocument`（旧文档 close 时 `consumeSwitch` 保会话，新文档 ReaderReady 依章会话重建）→ 预取 → `emitToSource("chapter_changed")`。

chapters/ 内部角色：`session.lua` = 纯状态；`materialize.lua` = 目录/正文拉取+落盘+预取；`patches.lua` = ReaderUI 边界 hook；`navigate.lua` = 换章/落点/目录菜单。

## 5. 统计与同步

### 计时（stats/tracker.lua，只统计有 opens 身份的文档）

- **start**：`reader_ready` / `onResume` → 先 flush 兜底，再查身份，建 `_cur{ref, page, started_at}`。
- **翻页**：页变了才结清旧页（时长 <1s 丢弃）→ `DbQueue.run(StatsDB.add)` 写 `reading_stats`，**一页一条**。
- **stop**：`onCloseDocument` / `onSuspend` → flush 结清最后一页。

### 统计上报（stats/stats_sync.lua，时机由源自决）

moon 源 `onEvent`（`source/moon.lua:75`）：`document_close`/`suspend` → `StatsSync.pushWithUi`：

1. busy/节流检查（MIN_INTERVAL=20s）；
2. 注册阅读设备（device_id 存 `G_reader_settings`）；
3. **注册往返后重读** `StatsDB.allBySource`——关书刚落盘的最后一条能搭上；
4. `source:importReadingStatsAsync` 上行 → 成功后 `DbQueue.run(StatsDB.deleteIds)` 删本地记录。

local 源不上报，`reading_stats` 留给洞察页本地聚合。

### 进度同步（book/progress.lua）

- **写**（关书/休眠时 `Progress.push`）：先 `enqueue` 写 `pending_progress`（掉电不丢）→ 在线则 `putProgressAsync` 上行 → 成功后确认队列里仍是同一版本才删本地 → 再 `flushPendingAsync` drain 积压（nextTick 串行逐条）。
- **拉**（reader_ready 时 `Progress.pull`）：先补传积压 → `getProgressAsync` → 回调里重新校验当前文档身份 → 差异 <1% 跳过 → 按章模式走 `gotoChapter`，否则 XPointer 优先、`GotoPage` 兜底。

### 事件分发

`emitToSource` → 各源 `onEvent` 覆写：moon = 统计上报/设备注册；local = `desktop_open` 时扫盘；其它源默认空操作（`source/base.lua`）。

## 6. 缓存（两套互不相关）

- **`book/cache.lua`** = 落盘文件缓存管理（`.moon/cache/<source>/book|image/`）：
  - `cleanupStaleAsync`（子进程，主页首载触发）：清 7 天过期 meta → 90 天未打开的书目录删除 → 清失效 opens 行。
  - `clearAsync`（设置页「清缓存」）：先子进程清 DB（opens 全清 + books stripMeta）再协作式删文件（每拍 24 项，不堵 UI）。
- **`http/cache.lua`** = HTTP GET 响应缓存（`http` 表：key=`METHOD path?规范化query`）：只存成功且 ttl>0 的响应；换源/手动失效。封面图片不走它，走 `ui/components/image.lua` 落 `image/` 目录。

## 7. utils/db 总览

单文件 `$DATA/.moon/book.sqlite3`，WAL + busy_timeout=5000，schema 一次 CREATE IF NOT EXISTS。子进程 fork 后必须重开连接。

| 表 | 写时机 | 读时机 |
|---|---|---|
| `books` | 列表/主页/详情展示时顺手 upsert；刮削 `putMetaAsync` | 详情 reload、local 源列表/洞察、最近阅读 JOIN |
| `opens` | `touchAsync`：整本打开、按章首开、每次切章 | `identityFor`（身份自举/Tracker/Progress）、缓存清理 |
| `reading_stats` | `Tracker` 翻页/关书/休眠，一页一条 | `StatsSync` 上报后 deleteIds；local 洞察页聚合 |
| `pending_progress` | 关书/休眠 `enqueue` | 上行成功后 delete；pull 前/手动补传 drain |
| `http` | GET 成功且 ttl>0 | 同名请求命中；换源/手动 clear |

## 端到端时序：一次完整阅读（moon 源整本书）

```
点书 → 详情浮层 → Store.remember（books 表 upsert，异步）
点开始阅读 → 缓存命中或下载 → touchAsync（opens 表）→ 关桌面 → showReader
ReaderReady → 查 opens 认身份 → Tracker 开始计时 → 拉远端进度(>1% 才跳)
           → 注入点按区+进度条 → emitToSource("reader_ready") → 源注册设备
翻页×N → 每页结清 → reading_stats 插一条 → 进度条重绘 → page_changed 事件
返回关书 → pending_progress 落盘 → putProgressAsync 上行 → 删 pending → drain 积压
        → Tracker 结清最后一页 → reading_stats 落盘
        → emitToSource("document_close") → StatsSync 上行 → 成功删本地
        → 会话销毁（_cur=nil，进度条停画）
中途休眠 = 同一套 push/stop 语义（事件名 suspend）；唤醒 onResume 仅重新计时
```

按章书的差异：打开走 `prepareOpenAsync → ensureAsync → bind → touchAsync(chapter_idx) → showInitial + 预取`；阅读中翻到头尾自动 `gotoChapter`（关旧文档 → `consumeSwitch` 保会话 → 新文档 ReaderReady 重建），每次切章都刷新 opens 的 path/chapter_idx。
