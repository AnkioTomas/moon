# 已注册源

`registry` ORDER：`local` → `moon` → `wechat` → `jdread` → `copymanga` → `fanqie`。

实现目录：`source/<id>.lua` + `source/<id>/`。

## 对照

| id | 形态 | stable_id | 书架 | 打开 | 进度/笔记/统计 | 其它 |
|---|---|---|---|---|---|---|
| `local` | book | 文件绝对路径 | 扫盘 | 直接 path + touch | 无远端 | scrape/edit；`dirty_only` 跳过扫盘 |
| `moon` | book | 远端文件名 | 快照↔（无 add API，delete↑） | 下载校验后打开 | 双向；`stats_pull` | search/refresh/insight |
| `wechat` | chapter | 微信 bookId | 快照↔ + add/delete | 章 HTML | 双向；`stats_pull` | 源内书城；全章缓存能力 |
| `jdread` | chapter | 京东侧 ID | 远端书架 | 章内容 | 进度等（无 `stats_pull`） | search/refresh/insight |
| `copymanga` | chapter | 漫画 ID | 收藏列表；删=取消收藏 | 章 CBZ | 进度（章粒度；push 靠带 token 的 chapter GET 副作用） | search/insight |
| `fanqie` | chapter | 番茄侧 ID | 书架（暂无脏成员推送；`dirty_only` skipped） | 官方网页正文 | 阅读位置由章节框架管 | cookie/扫码；可复用旧插件 `settings/fanqie.lua` |

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

- 正文仅官方网页接口；无完整阅读权限时返回错误。
- 阻塞 HTTP/解析走 `workers.job`，不要源内自造 Async。
- 协议改编自 fanqie.koplugin 网页适配版；发布物不含 Cookie/正文缓存。

## 怎么加一个源

1. 实现 `meta` / `new` / `capabilities` / `configured`
2. 覆盖需要的 `syncBooksAsync`、`openBookAsync`、进度/笔记/统计
3. 章源复用 [`chapter`](chapter.md) 落盘约定
4. `registry.FACTORIES` + `ORDER` 注册一行
5. `source/<id>/setting.lua` 挂设置页
6. 补 `tests/source/<id>/…_spec.lua`
