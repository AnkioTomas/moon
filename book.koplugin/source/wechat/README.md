# 微信读书

## 协议与能力

本源不是 App 协议的完整复刻，而是以 App 接口为主、混用公开 Web 接口的适配：

| 功能 | 当前协议 |
|---|---|
| 登录与令牌续期 | 官方微信扫码；`i.weread.qq.com` 的 `/wxticket`、微信扫码状态接口、`/login` |
| 书架、书籍、目录、阅读进度 | App API：`/shelf/sync`、`/shelf/syncbook`、`/shelf/add`、`/shelf/delete`、`/book/info`、`/book/chapterInfos`、`/book/getProgress` |
| 正文 | App API：`/book/chapterdownload`；EPUB/TXT 包在本机解包 |
| 进度与阅读时长 | App API：`/book/read`、`/book/batchUploadProgress`；本地先落库，联网后推送 |
| 「在读」状态 | Web Reader：`GET /web/reader/<book>` 取得会话参数，`POST /web/book/read` 以 `rt=0` 心跳；不增加阅读时长 |
| 划线、想法与他人段评 | App API：`/book/bookmarklist`、`/book/readreviews` 等 |
| 书城分类与列表 | Web API：`weread.qq.com/web/categories`、`/web/bookListInCategory/...`；搜索走 App `/store/search` |

App API 请求使用 `i.weread.qq.com`，扫码使用微信开放平台；书城 Web 请求使用 `weread.qq.com`。账号接口需要扫码会话，公开书城分类与列表不附账号会话。接口字段以当前实现和本地核对的官方 APK 为准，不代表所有 App 功能都已接入。

## 同步行为

首次同步、账号变化或游标失效时用 `synckey=0` 拉全量快照；成功后保存与 `vid` 绑定的游标。后续后台同步使用 `/shelf/sync` 增量索引，并以 `/shelf/syncbook` 补变更书籍；手动强制刷新使用全量快照。增量计数或响应形状无法确认时也回退全量。加入和删除先在本地生效，再经 `/shelf/add`、`/shelf/delete` 推送；仅推本地脏变更时只推加删，不拉全量快照。

超过设备解码上限的全量响应会原文落盘，由远程管理网页在浏览器分批解码和导入。导入完成前不会推进增量游标，也不会对账下架本地书。后台同步只保存待导入快照，不会弹出二维码导入页；用户手动刷新时才打开导入页。待导入快照期间，后台同步安静跳过，手动刷新可重新打开并从头重跑导入，或明确丢弃。

离线时本地变化保留为待同步状态；远端失败不会回滚本地书架。换账号会因 `vid` 不同而作废旧游标，旧书架数据不会自动清库。

开书时由阅读会话调用 `/book/getProgress`，先对比并处理本地与云端位置；存在冲突时，用户选择前不会自动上推。决议后翻页立即落本地，阅读中的位置与已结算时长最多每 5 秒合并推送一次 App `/book/read`；关书 / 休眠结算剩余时长并推送，离线则保留脏状态等待联网同步。阅读中请求失败不会丢本地位置或时长。阅读会话打开后另用 Web `/web/book/read` 每 30 秒发送 `rt=0` 心跳维持「在读」状态，阅读时长仍只由 App 小时桶上报；此零时长 Web 行为尚未用真实账号回读验证。

## 边界与核对记录

- 本地静态核对日期：2026-11-07；对象为用户提供的 APK 与当前源代码。APK 的书架服务确认使用 `/shelf/sync` 的 `synckey`、`onlyBookid`、`localBookCount` 参数，以及 `/shelf/syncbook`；阅读上报模型确认有小时桶和批量补报字段。
- 本次没有使用真实账号执行登录、读写书架或远端回读，因此不宣称完整端到端同步已实测。
- Web 书城仍非 App API；设备身份头、版本头和所有未使用的 App 功能也不等同于完整复刻。官网/API 行为可能随版本变化，失败分支需以真实授权会话复测。
