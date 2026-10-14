# source

书籍数据源。一个源 = 一种书从哪来、怎么打开、哪些域能和远端对账。

图书馆、筛选、搜索、最近阅读、洞察**只读本地 SQLite**（`book.catalog`）。
身份、进度、笔记、统计这些跨源的书籍领域模块在 `book/`，不在这里。
源的网络只出现在：书架同步、开书 / 下正文、进度、笔记、统计。
不支持的域异步返回 `skipped`，不当失败。

`store/zlib`、`store/opds` 是书城，不是 BookSource。下载后经 `local.importBookAsync` 入库。

## 目录

```text
source/
├── base.lua            契约；联网后只推本源脏行
├── registry.lua        源 id 清单、实例缓存、活跃 / 启用配置
├── shelf.lua           有 add/remove 书架 API 的双向同步（微信、京东）
├── chapter.lua         按章源的落盘：目录、正文、预取、全本缓存
├── toc.lua             books.toc 的读缓存（键含 source_id）
├── assets.lua          章节远程图落地（源注入 download，这里不碰鉴权）
└── <id>/
    ├── init.lua        必需。门面：meta / new / 覆盖自己支持的方法
    ├── setting.lua     可选。设置入口（open / rows / rowStatus …），设置页按这个文件名找
    └── …               其余文件怎么拆由源自己决定，外部不依赖
```

源对外只有这两个约定。`source/` 之外的代码只碰 `source.<id>`（经 registry）和 `source.<id>.setting`，
不 require 源目录里的其它文件，也不读源实例的私有字段（`_client` 之类）。

门面模块名是 `source.<id>`，文件在 `source/<id>/init.lua`。
`require("source.wechat")` 靠 `?/init.lua` 命中它。禁止再写 `require("source.wechat.init")`：同一文件两种名字会加载两份状态。

## 契约

实例继承 `source.base` 的 `SourceBase`。IO 一律 `XxxAsync(..., cb)`，返回可取消 job；取消后不回调。
无 IO 的方法保持同步：`capabilities`、`configured`、`coverRequest`。

`type` 只有两种：

| type | 打开时拿到什么 |
|---|---|
| `book` | 一个整本文件（epub / pdf / mobi …） |
| `chapter` | 某一章的 HTML。目录在 `books.toc`，正文由 `source.chapter` 落盘 |

身份是 `source_id + stable_id`。阅读会话按**这本书的属主源**操作，不拿 `registry.current()` 去动另一本书。换源串书就是从这里来的。

四个同步域，探测方式固定：

| 域 | 双向的条件 | 不支持时 |
|---|---|---|
| 书架 `syncBooksAsync` | 源自己实现。`dirty_only` 只推本地删/加，不拉快照 | 基类 `skipped` |
| 进度 | 同时有 `getProgressAsync` + `putProgressAsync` | `book.progress` 标 skipped |
| 笔记 | 同时有 `pushNotesAsync` + `pullNotesAsync` | `book.note` 标 skipped |
| 统计 | 有 `pushStatsAsync` 才推；`capabilities.stats_pull` 才拉 | 缺哪边就跳哪边 |

进度 pull 只在开书，冲突 ≥1% 让用户选一次。笔记有网即推，开书再拉。关书 progress / notes / stats 一律 `dirty_only`（只推不拉）。
断网或推送失败留下的脏行由 `pushDirty` 推（main 在启动、唤醒、联网时触发，作为后台任务入队、失败退避重试）：书架、笔记、统计，进度最后。没有脏行的域不调用。

书架的共同形状：远端快照 `book.store.reconcile`（pulled）+ 本地独有成员上行（pushed）。本地删除先标 `deleted`，推成功再撕墓碑。

### 能力表

`capabilities()` 是 UI 开关，不是「文件里有没有这个函数」。

| 键 | 谁读 | 含义 |
|---|---|---|
| `stats_pull` | `book.stats` | 拉远端统计入库 |
| `scrape` | 刮削 | 允许把外部元数据写进这本书 |
| `edit` | 详情编辑 | 允许改展示元信息 |

默认全 `false`。判断用 `== true`（`SourceCapabilities.supports*`）。
全本章节缓存看源上有没有 `cacheAllChaptersAsync`，不进能力表。

### 注册表

内置源登记在 `registry.lua` 的 `BUILTIN`，不扫 `source/` 目录，顺序即选择器顺序：本地、其余在线源。
第三方源由已启用 KOReader 插件根目录的 `moon_source.lua` 登记，排在内置源之后（契约见 `docs/source/external.md`，示例 `examples/moonsource-demo.koplugin/`）。

- 每个 id 一个缓存实例；活跃源只是配置 id（`common.active_source`），`current()` 就是 `resolve(activeId())`，不做静默 fallback；存的 id 已下线（如 kindle）时 `activeId()` 退回 local。
- `resolve(id)` 按书的 `source_id` 取属主实例，不改用户当前选择。
- 源模块加载失败直接抛出，不从列表里藏掉。
- `common.enabled_sources == nil` 表示全开；集合里没有的 id（后装的源）也算启用，只有显式 `false` 是禁用。活跃源禁止禁用。
- 登录态或连接配置变了走 `Registry.reload()`：关掉旧实例，广播 `SourceChanged`。

源没有插件生命周期钩子；main 只在启动、唤醒、联网时对有脏行且已配置的启用源调 `pushDirty`。
业务事件没有中转层，调用方直接 `source:onEvent`，基类全部空操作：

| 事件 | 谁发 | 谁覆盖 |
|---|---|---|
| `page_changed` | 阅读会话 | wechat（维持时长心跳） |
| `chapter_changed` | 按章会话开章 | wechat（进入阅读） |
| `reading_stopped` | 关书 / 休眠 | wechat（停时长心跳） |
| `reading_resumed` | 阅读中唤醒 | wechat（重启时长心跳） |
| `book_meta_changed` | 编辑 / 刮削已写库 | local（WebDAV 上行这本书） |

桌面打开、换源、图书馆刷新时的书架与统计同步不经过源事件，由 `desktop/sync.lua` 直接调 `syncBooksAsync` / `syncStatsAsync`：
`Sync.open` 后台同步（统计 5 分钟节流），`Sync.refresh` 强制同步并把书架任务放进任务队列。同步范围跟图书馆展示范围一致：混合模式下是全部已启用且已配置的源，否则只有活跃源。源未配置时，后台打开静默跳过，单源模式下手动刷新会提示，源有 `setting.open` 时附带「立即设置」按钮。
源没实现 `pushStatsAsync` 也没开 `stats_pull` 时，不同步统计。

## 新增一个源

1. `source/<id>/init.lua`：`meta()` + `new()`，继承 `SourceBase`，只覆盖自己真有的方法。模块名仍是 `source.<id>`。
2. 需要设置页就加 `source/<id>/setting.lua`；配置走 `utils.settings.getSource(id)`。协议、映射、登录怎么拆文件按源的实际复杂度来，不照抄别的源。
3. 在 `registry.lua` 的 `BUILTIN` 加一项。
4. `type = "chapter"` 的开书、预取、全本缓存走 `source.chapter`，目录缓存直接 require `source.toc`。只有源自己有目录逻辑时才建 `<id>/toc.lua`（如 wechat 的格式版本判断），不建一行转发。
5. 书架若是标准的拉快照 + add / remove，用 `source.shelf`：`Shelf.syncAsync(self.id, remote, to_books, opts, cb)`，`remote` 由源自己传，提供 `shelfSyncAsync` / `addToShelfAsync` / `removeFromShelfAsync`。协议对不上就在门面里写，别硬套；但推墓碑一律用 `Shelf.pushDeletes(self.id, remove_one, report, cb)`，源只给「远端删一本」，不再自己写串行循环。
6. 文案走 gettext。模块顶部不要 require KOReader UI（`UIManager`、`NetworkMgr`），函数内再加载。

测试放 `tests/source/<id>/`。

## 各源

### local — 本地书籍（`book`）

扫一个目录，或挂 WebDAV。`stable_id` 是文件绝对路径；WebDAV 书用远端路径，打开时拉到本地缓存再 `Store.touch`。

| 域 | 纯目录 | WebDAV |
|---|---|---|
| 书架 | 扫盘写 `books`。`dirty_only` 跳过 | 扫远端 + `books.sync` 对账。`dirty_only` 推删除并回写书目改动 |
| 进度 / 笔记 / 统计 | skipped | 走 `.Moon+/` 下的进度、笔记、统计文件 |
| 删除 | 删文件并删库行 | 删远端，本地留墓碑直到对账完成 |
| 推脏 `pushDirty` | 不入队（没有远端，脏行推不出去） | 照常入队 |

`scrape` / `edit` 只有这个源为 true。改分类/系列 = 移动文件（`stable_id` 跟着变）；WebDAV 下分类只是元数据，不搬文件。
书城导入走 `importBookAsync`。

`local/client.lua` 只管配置、路径和方法装配，实现按职责拆开：`scan.lua`（本地目录扫盘 / 导入 / 移动）、`webdav.lua`（books.sync 同步流水线、按需下载、删除、单本上行、连通性测试）、`remote_data.lua`（`.Moon+/` 下的进度、统计、笔记文件）、`common.lua`（共享原语：路径与边车寻址、文件读写、目录遍历、元数据与封面解析）。子模块函数首参即 `self`，在 `client.lua` 末尾逐个赋给 `Client`；子模块之间不互相 require。

### moon — 月读服务（`book`）

Bearer Token。整本文件下载到书籍工作目录，扩展名从 `stable_id` 认，认不出就当 epub。

书架：分页拉全量，先推本地待删（`Shelf.pushDeletes`），再 reconcile。**没有加书 API**，所以只有 list / delete，本地新加的书推不上去。
进度、笔记、统计都双向。统计 pull 是账户级 `page_stat` 快照，入库前按 replace 策略清掉已同步行，避免和本地页记录双计。

### wechat — 微信读书（`chapter`）

能力最全的在线源：书架、进度、笔记、统计都双向，`stats_pull = true`。

登录是两套会话，别混：

- `eink.lua`：扫码，拿到 accessToken / refreshToken。设置页走这条。
- `auth.lua`：网页 cookie。正文、笔记、部分统计走网页接口。Eink 换到的 token 同时是网页会话。

书架用 `source.shelf`（`shelfSyncAsync` / `addToShelfAsync` / `removeFromShelfAsync`）。
目录缓存带 `toc_version`，旧格式 `isTocCurrent` 为 false，强制重拉。TTL 6 小时，在 `source.toc`。
开章发「进入阅读」（`chapter_changed` → `putProgressAsync`）。服务端只认距上次上报的间隔，所以 enter 必须在时长上报之前；开书拉进度期间先挂起，避免抢在冲突选择前写云端位置。
阅读时长走定时心跳，与 weread.koplugin 一致：开章 / 翻页 / 唤醒（`reading_resumed`）起心跳，阅读中每 30 秒报一次固定 `rt=30`，不看是否翻页，`reading_stopped`（关书 / 休眠）才停。上报会话按书一份：参数 `psvts`/`pclts`/`token` 取自真实网页阅读页，建成满 15 分钟重开阅读页重建并重新进入；上报失败强制重建再报一次，回包有没有 `synckey` 只记日志。离线、上一拍未回的那拍直接跳过，不补报；`pushStatsAsync` 只在本地确认统计行，不发请求。

划线不能当普通标注推。`notes.lua` 维护 `wr_bookmark_id` / `wr_review_id`，`annotations.lua` 把本地 xpointer 和网页 range 互定位。

| 文件 | 职责 |
|---|---|
| `client.lua` | 只返回 wire |
| `mapper.lua` | 书架 / 目录 / 进度 |
| `protocol.lua` | 签名、正文分片解码 |
| `chapter.lua` | 拉一章 HTML |
| `assets.lua` | tar 插图解包，解完交给 `source.assets` |
| `stats.lua` | 阅读时长 wire → `BookStatsRow` |

### jdread — 京东读书（`chapter`）

cookie + 设备 uuid。协议签名和章节下载 AES 在 `protocol.lua`（`e.m.jd.com`）。

书架用 `source.shelf`，和微信同一套。进度双向。没有笔记，没有统计拉取（`stats_pull = false`，也没有 `pushStatsAsync`）。
目录只认下载协议版本 5（EPUB 按文件成章，`indexes`；同文件锚点小节挂 `anchors`）和 3（网文，`type` + `ids`）。其余版本当场作废重拉。
未购买且非试读章节下载返回 `result_code = 101`。

### copymanga — 拷贝漫画（`chapter`）

App API `COPY/3.0.0`，`/api/v3/*`。默认 host `api.copy202601.com`。token 登录。

书架不是 add/remove，是收藏列表。删除 = 先查 `comic_id` 再 `setCollect(false)`，所以不用 `Shelf.syncAsync`，只把这两步当「删一本」交给 `Shelf.pushDeletes`。没有加架上行。
`dirty_only` 只推取消收藏。进度双向。没有笔记和统计。
一章是一组图片 URL（`protocol.lua` 把低清 `.c800x.` 换成 `.c1500x.`），不是 HTML 正文。
章节 CBZ 按章节 uuid 命名（`<uuid>.cbz`），不按连续章号：目录是各分组拼起来的，默认组更新后其它组章号整体后移。

### fanqie — 番茄小说（`chapter`）

cookie 登录（扫码在 `qrlogin.lua`）。正文不走网页 HTML，走 App reading API：`registerkey` → `batch_full` → 解密（`reading/`）。

书架只拉不推。`dirty_only` 直接 skipped，因为没有删/加 API。拉到的列表 reconcile。
详情不打网络，读本地库。进度双向。没有笔记，没有统计。
封面用手机端 CDN 的稳定路径（`fanqie/fanqie.lua` 的 `mobileCover`），网页签名 `thumb_url` 会过期。

文件拆法和其它源不同（配置包在 `settings.lua`、书架映射写在门面里），这不是问题。真正欠的债：

- 文案多处是硬编码中文，没走 gettext。
- 自己造了 `FanqieAsyncHandle`，而 HTTP 层已经返回 `{ cancel }`。

协议常量留在 `fanqie/fanqie.lua`，加解密留在 `reading/`。不要把这套对象包装再复制到新源。
