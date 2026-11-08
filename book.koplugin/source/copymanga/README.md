# 拷贝漫画

## 站点选择

「设置 → 书库 → 账号 → 拷贝漫画 → 站点地址」提供以下选项。
**当前建议选择 `https://api.manga2026.xyz`**，这是本次核对过的官方 App 节点。

| 用户选择的站点 | 实际请求的 API 主机 |
| --- | --- |
| `https://www.mangacopy.com/` | `https://api.mangacopy.com` |
| `https://www.copy4000.com/` | `https://api.copy4000.com` |
| `https://api.manga2026.xyz` | 同名主机；官方 3.1.0 包中的节点 |

`www` 是网页入口，不能直接拼 App API 路径；选择时映射到对应的 `api` 主机。
所有选项仍使用 `/api/v3/*`，**不解析官网 HTML，不保留另一套 Web 客户端**。
保留「自定义」API 地址和已有 `base_url`；未配置时仍用原来的
`https://api.copy202601.com`，不强制迁移老用户。也可以直接填写上表的 API 地址。
两个旧入口保持用户选择兼容，但本次旧 copy4000 节点拒绝匿名请求。
请求失败不会自动换站点、代理或轮换身份；新节点需用户主动选择。

换站点不改书籍身份、章节 UUID、本地目录与已下载 CBZ。旧实例退出登录后不会复用旧
Token；换站点后旧实例也不会取新站点的 Token 发请求。

## 能力

| 功能 | 实现与边界 |
| --- | --- |
| 账号密码登录 | 原 API 登录；新登录不保存密码 |
| 搜索与书城 | API 搜索、男女频日 / 周 / 月 / 总榜与题材；每页 20 本，默认聚合 60 本 |
| 详情与目录 | API 返回元数据，分组分页目录；默认组在前，保留章节 UUID |
| 章节阅读 | API 图片列表按阅读序号排序，下载为 CBZ，交给 KOReader 阅读器 |
| 章节缓存 | 复用已有 CBZ；离线直接打开已缓存章节，未缓存内容离线立即报错 |
| 书架双向同步 | 分页拉收藏；补全本地新加书的收藏上行，保留删除上行；写后回读确认 |
| 进度 | 旧 API 保留章粒度读写；当前节点尚未验证写入与回读，仅保存本地进度，不声明云端同步 |
| 笔记与阅读统计 | 本地保存，无远端同步接口 |
| Cookie / 扫码 / 验证码登录 | 未接入；本次没有可验证的 API 契约 |
| 评论、回复、付费分支 | 未补造接口；没有真实账号验证，不承诺受限章节可读 |

## API

请求头沿用原客户端的 `COPY/3.0.0`、`version`、`platform` 与 `region`。
公共元数据请求不附带账号 Token；书架与进度请求用 `Authorization: Token <token>`。
账号请求与登录不跟随重定向，登录响应不缓存。图片 CDN 不收到账号 Token。

| 用途 | 方法与路径 | 参数 / 响应 | 登录 |
| --- | --- | --- | --- |
| 登录 | `POST /api/v3/login` | `username,password,salt`；密码为 Base64(原值 + `-` + 六位 salt)，成功须有 Token 与账号 ID | 否 |
| 搜索 | `GET /api/v3/search/comic` | `q,q_type,platform=1,limit=30,offset=0`；`results.list,total` | 否 |
| 榜单 | `GET /api/v3/ranks` | `type=1,date_type,platform=1,audience_type?,limit=20,offset` | 否 |
| 题材 | `GET /api/v3/comics` | `theme,free_type=1,ordering=-popular,limit=20,offset` | 否 |
| 详情 | `GET /api/v3/comic2/<path_word>` | `results.comic,groups` | 否 |
| 目录 | `GET /api/v3/comic/<path_word>/group/<group>/chapters` | `limit=100,offset,platform=1`；分页章节 UUID | 否 |
| 章节 | 当前节点 `GET /api/v3/comic/<path_word>/chapter/<uuid>`；旧节点用 `chapter2` | `platform=1`；复用原图片顺序与 CBZ 管线。当前节点的 `chapter2` 返回 404，不能直接套旧路径 | 受限分支未验证 |
| 收藏列表 | `GET /api/v3/member/collect/comics` | `free_type=1,limit=50,offset,ordering=-datetime_updated` | 是 |
| 收藏增删 | `POST /api/v3/member/collect/comic` | `comic_id,is_collect=1/0,authorization`；成功后拉收藏确认成员状态 | 是 |
| 读取进度（旧 API） | `GET /api/v3/comic2/<path_word>/query` | `platform=1`；浏览记录中的章节 UUID | 是 |
| 推进度（旧 API） | `GET /api/v3/comic/<path_word>/chapter2/<uuid>` | 沿用原副作用；不能推断当前节点的 `chapter` 同样会写进度 | 是 |

`code=210` 是 API 拒绝请求，不是成功、空列表，也不能据此认定当前用户账号被风控。
优先原样显示服务端的处理提示；没有有效提示时明确报告 API 拒绝请求。保留本地状态，
不自动重登、切线路或将失败伪装成空结果。
收藏缺少 `list`、坏漫画身份、分页中断、写后回读不一致都算失败，不能清空本地书架
或确认删除。分页以本次请求的 offset 判断，兼容响应未回传 offset 的情况。

## 本地与账号

书籍身份是 `copymanga + path_word`；缓存按章节 UUID 命名，换站点不串章。
本地加架立即生效并标脏，下次同步收藏；删除先清缓存、留墓碑，远端确认后才撕墓碑。
直接复用公共 `Shelf.syncAsync`，不另写一套上行与对账。

成功登录才替换 Token。取消、失败、迟到响应或登录期间切站不覆盖新会话。
禁止直接换到另一个账号；旧 Token 缺账号 ID 时同样要求先退出。退出经通用确认入口
清本地书架、进度、笔记和缓存，不触发远端删书。

新登录不保存密码；历史保存的密码仅用于原自动重登兼容，成功后清除。
之后 Token 失效需重新输入密码。密码按原值编码，不裁剪首尾空格。

## 检查记录与限制

核对日期：2026-11-07 至 2026-11-08。没有使用真实账号凭据，没有远端增删或付费操作。
网页协议研究曾在独立模拟器进行，runtime、`KO_HOME` 与缓存都隔离于真实 `config/`；
最终实现已删除该 HTML 分支，不能将此前网页结果当成当前 API 全流程通过。

匿名实测 `https://api.copy4000.com/api/v3/comic2/hunhuan?platform=1` 返回 API JSON，
业务码为 `210`，提示安装官方 App 后等待限制解除。`api.mangacopy.com` 在本机 TLS
连接被重置。没有绕过风控、伪造设备指纹或使用代理。两个旧主机的真实全流程仍未通过。

2026-11-08 复核：不带账号 Token 的 curl 请求也返回上述 `210`，不是模拟器专属问题，
也没有证据证明用户账号被限制。已删除将所有 `210` 统一改写为「账号被风控」的逻辑。
官网最新下载为 `3.1.0`（2026-10-28）。从官方包取得当前节点
`api.manga2026.xyz`，使用**同一套原有请求头与同一 `comic2` 路径**对照：
旧 copy4000 返回 `210`，当前节点返回 `200`。因此已确认节点兼容性差异，
没有凭版本号猜测修改 `COPY/3.0.0` / `2025.08.15`，也没有添加设备指纹或鉴权伪装。

当前节点匿名实测：搜索 30 条、详情成功、目录 47 章、章节接口返回 40 个图片地址、
榜单 20 条、题材三页合计 60 条。章节使用 `/chapter/`；旧 `/chapter2/` 返回 404，
已按节点保留对应路由。

**图片下载尚未通过**：服务器返回的第一张原图在 `sh.mangafunb.fun`，返回 HTTP 403；
原图 URL 未被档位转换改变，去掉额外 Referer 后仍被拒绝。没有绕过 CDN 访问限制。
因此不能声称 CBZ 阅读、完整缓存或离线重开通过。没有真实账号授权，登录、收藏增删、
付费权限和进度写入未实测；新节点不将成功取得图片列表当作云端进度同步成功。

离线回归覆盖两站点映射、统一 API 路由、站点选择、原有目录 / 图片 / CBZ / 进度行为、
本地加删同步、写后回读、坏响应、分页、取消和账号边界；源目录 LuaLS 无告警。
这些结果证明代码契约与回归，不代替受风控阻断的真实服务验证。
