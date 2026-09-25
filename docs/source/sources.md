# 已注册源

`registry` ORDER：`local` → `moon` → `wechat` → `jdread` → `copymanga` → `fanqie`。

实现目录：`source/<id>.lua` + `source/<id>/`。

## 对照

| id | 形态 | stable_id | 书架 | 打开 | 进度/笔记/统计 | 其它 |
|---|---|---|---|---|---|---|
| `local` | book | 文件绝对路径；WebDAV 模式为 `webdav://相对路径` | 扫盘（WebDAV 模式扫远端目录并同步书目） | 直接 path + touch；WebDAV 按需下载 | 无云书库 API；WebDAV 模式经 `syncProgressAsync` 推进度文件 | scrape/edit；`dirty_only` 跳过扫盘 |
| `moon` | book | 远端文件名 | 快照↔（无 add API，delete↑） | 下载校验后打开 | 双向；`stats_pull` | search/refresh/insight |
| `wechat` | chapter | 微信 bookId | 快照↔ + add/delete | 章 HTML | 双向；`stats_pull` | 全章缓存（`cacheAllChaptersAsync`） |
| `jdread` | chapter | 京东侧 ID | 远端书架 | 章内容 | 进度等（无 `stats_pull`） | search/refresh/insight |
| `copymanga` | chapter | 漫画 ID | 收藏列表；删=取消收藏 | 章 CBZ | 进度（章粒度；push 靠带 token 的 chapter GET 副作用） | search/insight |
| `fanqie` | chapter | 番茄侧 ID | 书架（暂无脏成员推送；`dirty_only` skipped） | App reading API 正文（`batch_full` 解密） | 进度双向（`getProgressAsync` / `putProgressAsync`）；无笔记、无 `stats_pull` | cookie/扫码；配置落 `utils.settings.getSource("fanqie")` |

## 能力字段（UI 实际读取）

见 `Source:capabilities()` / `SourceCapabilities.defaults()`：

| 字段 | 含义 |
|---|---|
| `search` | 图书馆关键词 |
| `refresh` | 手动强制重扫/刷新 |
| `scrape` / `edit` | 刮削与编辑元数据（通常仅 local） |
| `insight` | 统计洞察页 |
| `stats_pull` | 是否拉远端统计写入本地 |
| `cacheAllChaptersAsync` | 可选，全本章节缓存 |

## 番茄补充

- 正文仅走 App reading API（`registerkey` → `batch_full` → 解密）；失败时 `cb(nil, err)`（风控空响应、解密失败等）。
- 网络只走 `http.request`（异步 + `{ cancel }`），禁止 `socket.http` / 源内自造 Async。
- 书架 / 目录等走网页 API；正文协议来自 fanqie-re（见 `source/fanqie/reading.lua`）。发布物不含 Cookie/正文缓存。
- 章缓存走 `source.chapter` → `Paths.chapterPath`；配置走 `utils.settings.getSource("fanqie")`。

## 怎么加一个源

1. 实现 `meta` / `new` / `capabilities` / `configured`
2. 覆盖需要的 `syncBooksAsync`、`openBookAsync`、进度/笔记/统计
3. 章源复用 [`chapter`](chapter.md) 落盘约定
4. `registry.FACTORIES` + `ORDER` 注册一行
5. `source/<id>/setting.lua` 挂设置页
6. 补 `tests/source/<id>/…_spec.lua`
