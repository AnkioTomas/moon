# 第三方书源

第三方书源是一个独立的 KOReader 插件，和月读一起装进 `plugins/`。月读启动后在源选择器里列出它，书架、开书、进度、笔记、统计和内置源走同一套流程。

完整可运行的示例：[`examples/moonsource-demo.koplugin/`](../../examples/moonsource-demo.koplugin/)（离线的三章静态书，`chapter` 型）；真实书源：[`extensions/moonsource-kavita.koplugin/`](../../extensions/moonsource-kavita.koplugin/)（Kavita 服务器，`book` 型，带下载、选卷、进度双向、划线上传、漫画交 kamare 在线看、首页 On Deck、网页配置）；[`extensions/moonsource-bookorbit.koplugin/`](../../extensions/moonsource-bookorbit.koplugin/)（BookOrbit 服务器，`book` 型，走它给 KOReader 插件开的接口：按库同步书架、下载原件、kosync 兼容的进度双向、划线只上传、可导入官方插件的账号）。

## 目录

```text
moonsource-xxx.koplugin/
├── _meta.lua          KOReader 插件元信息（fullname / description）
├── main.lua           返回一个空 WidgetContainer；返回 nil 会被 KOReader 当成加载失败
├── moon_source.lua    描述文件，月读只认这个文件名
└── moonsource_xxx/    可选：自己的子模块，目录名带唯一前缀
```

KOReader 加载完全部插件后，月读在首次访问源注册表时对每个**已启用**插件检查 `<插件目录>/moon_source.lua`，有就 `dofile`，结果缓存到重启。插件加载期间注册表只有内置源，不会读描述文件。用户在 KOReader 插件管理里禁用插件，这个源就消失。

`dofile` 时所有插件目录都已在 `package.path` 上，可以 `require` 月读模块。所有插件共用一个 `package.path`，同名模块谁先加载算谁的，所以自己的子模块不要叫 `client`、`utils` 这类通用名，放进带前缀的目录：`require("moonsource_xxx.client")`。

## 描述文件

```lua
return {
    api = 1,                  -- 契约版本，必须等于月读的 Registry.API
    meta = function()         -- 无 IO，可多次调用
        return { id = "ext.xxx", name = "我的书源", type = "chapter" }
    end,
    new = function()          -- 返回源实例，继承 source.base
        ...
    end,
    setting = nil,            -- 可选：设置入口模块，见下文
    home = nil,               -- 可选：首页组件数组，见下文
}
```

规则（不满足就不加载，只写错误日志）：

- `api` 不等于月读的 `Registry.API`。契约有不兼容改动时月读会升版本，旧书源需要跟着改。
- `id` 必须是 `ext.<name>`，`<name>` 只能用字母、数字、`_`、`-`。id 写进书库（`books.source_id`）和配置文件名，**发布后不能改**，改了等于换了一个源，旧书全部失联。
- id 与已登记的源重名时，先加载的插件生效。

`type` 只有两种：`book`（打开时交一个整本文件）和 `chapter`（按章交 HTML）。

## 源实例

继承 `source.base` 的 `SourceBase`，只覆盖自己真有的方法。完整契约见 [`base`](base.md) 和 `book.koplugin/source/README.md`。IO 方法一律 `XxxAsync(..., cb)`，返回 `{ cancel }`，取消后不回调；当场就能回的结果也要用 `SourceBase.defer(cb, ...)` 下一帧回调。

最少要实现：

| 方法 | 说明 |
|---|---|
| `configured()` | 是否已配置到能发请求（登录、地址）；false 时桌面同步静默跳过、手动刷新提示 |
| `syncBooksAsync(opts, cb)` | 拉书架快照交 `require("source.shelf").reconcile(self.id, books)`；`opts.dirty_only` 时只推本地删改，没有远端删除接口就 `SourceBase.skipped(cb, reason)` |
| `openBookAsync(identity, opts, cb)` | `book`：下载到书籍目录后 `require("book.store").touch(path, identity)` 再回调路径；`chapter`：交给 `source.chapter` 的 `openWithUi` / `openAsync`。源自己把内容展示出来了（比如交给别的插件的查看器）就回调 `cb(nil, nil, { handled = true })`，桌面不开阅读器也不提示 |
| `loadTocAsync(identity, cb)` | 仅 `chapter`：目录 `BookChapter[]`，用 `source.toc.put` 写缓存 |

可选：

- `getDetailAsync(identity, cb)`：取详情并经 `rememberMany` 落库，回调 `Book`。`chapter` 型开书前调用；任何类型在详情页发现书库里没有简介、且在线时也会调一次（只请求，不弹联网）。
- `prefetchChaptersAsync`、`cacheAllChaptersAsync`（详情页出现「缓存全本」）。
- `getProgressAsync` + `putProgressAsync`（进度双向；阅读快捷面板的「推送进度 / 拉取进度」按这两个方法是否存在出现）。
- `pushNotesAsync` + `pullNotesAsync`（笔记双向，只推也行）。推送时可以往注解表里原地写远端 id，核心会把推送后的快照落库；要让这些私有字段活过下一次保存，同时实现 `cleanAnnotations(items, total_pages)`（清洗时保留私有字段）和 `prepareLocalAnnotations(previous, current)`（按位置把上一版的私有字段搬到新快照）。
- `pushStatsAsync`、`coverRequest`（封面需要鉴权头时）、`onEvent`、`close`。

没实现的域自动跳过，不算失败。

`Book` 至少要有 `source_id`、`stable_id`、`title`；`stable_id` 是源内书籍身份，同样不能改。

## 可以 require 的月读模块

只依赖下面这些，其余模块不是对外接口，随时可能改：

| 模块 | 用途 |
|---|---|
| `source.base` | 基类、`defer`、`skipped` |
| `source.shelf` | `reconcile`、`pushDeletes`、`syncAsync` |
| `source.chapter` | 按章打开、预取、全本缓存 |
| `source.toc` | 目录缓存 |
| `book.store` | `touch`（整本源开书后登记路径）、`rememberMany`（写书籍元数据；不带 `deleted` 的新行不上书架；空串简介按 NULL 存） |
| `book.books_db` | 只读：`get(source_id, stable_id)`（取登记路径）、`getToc(source_id, stable_id)`（不限时读旧目录，离线兜底）、`libraryStableIdsBySource(source_id)`（本地书架成员） |
| `book.progress_db` | `get(source_id, stable_id)`（本地进度，拉进度时判断是否同一位置）；`upsertRemote(source_id, stable_id, pos)`（写远端版进度，本地未同步的不覆盖，不会被推回去） |
| `book.note.normalize` | `clean(items, total_pages)`：核心的注解清洗，`cleanAnnotations` 在它基础上补私有字段 |
| `utils.paths` | 书籍目录、章节路径 |
| `utils.settings` | `getSource(id)` / `saveSource(id)`：源配置，落盘 `settings/<id>.lua` |
| `utils.log` | 日志 |
| `http.request` | 异步 HTTP（返回 `{ cancel }`） |
| `utils.text` | 文本处理 |
| `ui.themes.widgets.*` | 界面控件（`row` / `input` / `list` / `toast` / `progress_dialog` / `tap` / `text`），跟随月读主题 |
| `ui.widgets.book` | `cover(plugin, nil, book, w, h, opts)`：书籍封面（按 `book.source_id` 找源取图） |
| `desktop.pages.home.base` | 首页组件基类，见下文 |

模块顶层不要 require KOReader UI（`ui/uimanager`、`ui/network/manager`），放到函数里再加载。离线判断用 `NetworkMgr:isConnected()`，不要用会卡 UI 的 `isOnline()`。

## 设置入口

描述表的 `setting` 是一个模块表，出现在桌面设置「书籍来源」页，以源名为分节标题。二选一：

- `rows(plugin)` 返回行构造函数数组（`function(inner_width) return Row.widget{...} end`），自己画整节。
- `open(plugin)` 打开自己的设置窗口，月读画一行入口；可选 `rowStatus()` 返回 `status, status_on`，`rowTitle()`、`rowIcon()` 改行标题和图标。

有 `open` 时，手动刷新书架遇到 `configured()` 为假会提供「立即设置」按钮。

设置模块还可以带 `remote` 字段数组，远程管理的「连接配置」网页上就多一张这个源的表单（标题是源名），只读写声明过的键：

```lua
Setting.remote = {
    { key = "base_url", label = _("服务器地址"), type = "url", placeholder = "https://…",
      normalize = function(v) return require("utils.text").rtrimSlashes(v) end },
    { key = "api_key", label = _("API Key"), secret = true },  -- 读取脱敏，提交 ****** 表示不改
}
```

`normalize` 缺省去首尾空白。保存后源实例重建。要连服务器才能选的配置（比如书库列表）留在设备上的设置页。

## 首页组件

描述表的 `home` 是组件数组，追加在内置组件之后，用户在首页编辑里添加。组件 id 必须以 `ext.` 开头，和已有组件重名的不加载；插件被禁用后组件消失，首页放置随之丢弃。

组件继承 `desktop.pages.home.base`：声明 `id` / `label` / `icon`，实现 `heightRange()` 与 `createWidget()`（按 `self.ctx` / `self.opts.width/height` 拼控件），网络请求放在 `onActivate`、在 `onDeactivate` 里取消，数据到了调 `self:refresh()`。点书用 `Base.openBook(ctx, book)` 走月读的开书流程。实例在首页重建之间保留，数据可以挂在实例上复用。

## 启用与卸载

- 新装的源默认启用（包括用户已改过「已启用的数据源」的情况）。
- 卸载或禁用插件：如果它是当前源，月读退回本地源；它的书留在书库里但不显示，重装同一 id 后恢复。从 KOReader 历史记录直接打开它的已下载章节仍能阅读，只是不同步。
