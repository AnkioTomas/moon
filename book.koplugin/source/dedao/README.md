# 得到书源

源 ID：`dedao`。最近核对：2026-11-07。使用得到电脑官网 Web 协议，不是 App 私有协议。

## 可以做什么

| 能力 | 实现与边界 |
| --- | --- |
| 手机号登录 | 中国大陆手机号短信验证码登录，不是密码登录。发送前确认协议；未注册号码可能自动注册。候选 OAuth/Cookie 会话独立，校验账号成功后才保存。 |
| 短信安全验证 | 复用月读远程网页验证窗口，手机扫码完成官方网易易盾滑块，设备用同一候选会话继续发送短信。短信码仍在设备填写。网页只拿五分钟票据与验证码 ID，不拿手机号、OAuth、Cookie 或短信码。取消、过期、发送失败均不算登录或发短信成功。 |
| 扫码登录 | 得到 App 扫码，不是微信扫码；独立候选 Cookie、轮询、错误提示、取消、过期重取，成功后再校验账号。 |
| 书架拉取 | 分页拉取官网“已购”的电子书集合，过滤课程、听书和自上传内容；去重并检测无进展，不再把 40 页截断当成完整快照。加入集合不等于购买。 |
| 加入与移出 | 本地优先、标脏后同步；加入走 `bookshelf/add`，移出对齐当前“已购”页的 `product/pcremove`。尚未实测远端增删并回读，不能宣称全部写入已验证。 |
| 书城与搜索 | 动态分类、子分类、最热/最新及服务端显示的筛选，保留续页 `request_id`；书城和搜索聚合后续页，一次约 60 条，保留末页完整结果。 |
| 详情与目录 | 详情包含书名、作者、简介、封面；目录通过阅读 token 获取，按阅读顺序映射章节 ID、保留层级。普通电子书阅读接口不强加 `ptype=2`。 |
| 正文与缓存 | 分页取加密 SVG，AES-256-CBC 解密，按文字坐标还原行与段落；V2 排版配置采用官网的下划线字段。复用公共章节预取/全本缓存，兼容旧目录与旧合法 HTML，不再强制旧缓存联网重下。 |
| 整书书评 | 使用当前真实书评接口，分页去重，取 `note_line`/`note` 正文、作者、时间、评分；书评条数不等于评分人数。已经在独立模拟器读到 9 条非空书评。 |
| 阅读进度 | 拉取远端章节、上传本地章节 ID；仅章级，不是精确章内位置。 |
| 本地笔记与统计 | 月读核心本地记录可用，不要求得到在线；没有得到远端划线、笔记或统计同步。 |

## 尚未接入或需要继续验证

- **没有密码登录。** 可用手机号短信、App 扫码，或官网浏览器登录 / 粘贴 Cookie。
- **安全验证需要人工完成。** 手机与设备需能访问同一个月读远程验证服务，且浏览器能加载易盾；不自动破解滑块，不代发短信。已覆盖候选会话续接、错误、取消、超时与防重复提交；用户已完成真实短信登录和账号校验，但易盾滑块到短信续发的整条链路仍需实际触发验证后确认。
- **没有章评、公共段评或评论回复。** 已找到电子书笔记及笔记回复接口，但其坐标归属于笔记/原版页面，不可直接冒充章节段落。整书书评不等于段评。
- **进度只保留章级位置。** 上行固定 `windex=0`，下行不应用章内坐标，按目录项估全书比例；跨排版精确位置没有接入。
- **远端统计未接入。** 官网使用真实阅读时间区间上报；本地按日聚合秒数不能伪造成阅读区间。
- **账号隔离有限。** 新登录保存 `uid_hazy`；已绑定账号时拒绝直接换成另一账号，要求先公共退出。旧版本没有保存 uid 的凭证不具备完整迁移隔离，不能称为账号分区。
- **真实已登录阅读尚待验证。** 匿名普通阅读请求被 HTTP 401 拒绝；必须真实登录后验证目录、正文、全本缓存与离线续读。此前强传 `ptype=2` 得到的权限拒绝不是普通书正确调用的验证结论。
- **远端写入未做本轮实测。** 未购买、未对真实账号执行加入/移出、写进度或写笔记；需要用户明确授权后再操作并回读确认。

## 协议与主要接口

主域：`https://www.dedao.cn`。电脑请求带 `Xi-DT: web`、Cookie 与对应 `csrfToken` 的 `Xi-Csrf-Token`；登录接口另用 `X-Oauth-Access-Token`。业务通常返回 `{h:{c,e},c:...}`，OAuth 返回 `errCode/data`；HTTP 200 不等于业务成功。

普通请求使用设置中的完整网络超时（默认 30 秒），不再统一减半。传输失败在 `book.log` 记录方法、无查询参数的接口路径、超时类别及上限，不记录 Cookie、token、请求正文或原始错误里的凭证。一次书城加载包含筛选和多页列表请求，总耗时不是单条请求的超时。

| 用途 | 方法、路径 | 关键字段 |
| --- | --- | --- |
| 网页会话 / 登录令牌 | `GET /`；`POST /loginapi/getAccessToken` | 从 `Set-Cookie` 建 CSRF 与匿名 OAuth 会话。 |
| 发短信 / 安全验证续发 | `POST /oauth/api/embedded/auth_code/send` | `areaCode:"86"`、`phone`、`sysCode:"4"`、`pname`、`scene`；`needCaptcha/captchaId` 要求易盾。续发的 **`captcha` 是 `{captchaId,validate}` 对象**，必须沿用原 OAuth/Cookie 会话。 |
| 提交短信码 | `POST /oauth/api/embedded/auth_code/check` | `code`、`autoRegister`、`withUser`、`channelType`、`authByGW`、`expireTime`。 |
| 校验账号 | `GET /api/pc/user/info` | 校验并保存 `uid_hazy`，成功后才提交候选凭证。 |
| 创建 / 轮询二维码 | `GET /oauth/api/embedded/qrcode`；`POST /oauth/api/embedded/qrcode/check_login` | `qrCodeString`；`qrCode`、`keepLogin`。内容指向官方 `m.igetget.com/oauth/qrcode/v2/authorize`。 |
| 电子书集合 | `POST /api/hades/v2/product/list` | `category=ebook`、`filter`、`order`、`page`、`page_size=18`、`group_id`；`list/is_more`。 |
| 加入集合 | `POST /api/pc/ebook2/v1/bookshelf/add` | `book_enids`、`ptype=2`；不是购买接口。 |
| 移出“已购”列表 | `POST /api/pc/hades/v1/product/pcremove` | `data:[{pid,ptype:2}]`；不撤销购买。 |
| 书城筛选 | `POST /pc/label/v2/algo/pc/filter/list` | 动态 `navigations`、子分类及显示的筛选项。 |
| 书城列表 | `POST /pc/label/v2/algo/pc/product/list` | `nav_type=0`、`product_types:"2"`、`page` 从 0 开始、`page_size=20`、`sort_strategy`、`navigation_id`、`request_id`；`tags_ids` 为字符串数组，未选择时省略。 |
| 搜索 | `POST /api/search/pc/tophits` | `content`、`tab_type=2`、`page` 从 1 开始、`page_size=20`；模块式结果。 |
| 详情 | `GET /pc/ebook2/v1/pc/detail` | `id`、`ptype=2`；书名可能为 `operating_title`。 |
| 阅读 token / 目录 | `POST /api/pc/ebook2/v1/pc/read/token`；`GET /ebk_web/v1/get_book_info` | `id`；`token`，返回 `bookInfo.toc/orders`；普通书不传 `ptype`。 |
| 正文分页 | `POST /ebk_web_go/v2/get_pages` | `token`、`chapter_id`、`config`、`index`、`count`、`offset`；配置 `font_name/font_size/line_height/margin_*`。 |
| 拉取 / 上传进度 | `POST /api/pc/ebook2/v1/pc/getread`；`POST /api/pc/ebook2/v1/pc/addread` | `id`；上传 `findex/windex/summary`，普通书不传 `ptype`。 |
| **当前整书书评** | `POST /pc/ebook2/v1/comment/list` | `enid`、`page_size=20`、`page` 从 1 开始、`sort:"like_count"`、`ptype=2`。 |
| 评分详情（非当前书评列表） | `GET /pc/ebook2/v1/pc/score/detail` | `id`；空 `comment.list` 不能证明没有书评。 |
| 电子书笔记（未接） | `POST /api/pc/ledgers/ebook/list` | `book_enid/book_id/is_old_version/ptype`；原版位置在 `extra`。 |
| 笔记回复（未接） | `/pc/ledgers/comment/list`、`/pc/ledgers/comment/list/list_v2` | 绑定笔记/内容身份，不是只凭章节 ID 获取段评。 |

## 本地、删除和换号

本地 SQLite 与文件是唯一真相。加入先写本地并标脏；删除先清缓存、写墓碑，书架立即隐藏，联网后由公共任务队列推远端；失败保留墓碑，远端确认后才撕墓碑。删除入口不先发网络请求。未配置账号没有远端对象，本地删除可直接完成。

全量同步为“推删 → 拉集合 → 推本地新增 → 必要时再拉 → 对账”；`dirty_only` 只推不拉。退出走公共确认流程，停任务、清凭证、清本源本地书架/进度/笔记/缓存，不发远端删除；本地未同步记录会丢失。

## 实测证据与修复

- 独立模拟器使用全新数据目录、真实联网，不复制用户账号；实际书城取得 60 本、两组筛选，实际整书书评取得 9 条非空正文。
- 搜索与书评分页、44 页书架完整性、坏响应、无进展、迟到回调、旧 Cookie 不污染新会话、候选登录、验证码凭据结构及验证窗口取消均有离线回归。
- 已修旧缓存联网失效、书架 40 页截断、坏书架响应无错误、多阶段取消句柄覆盖、旧请求使新会话失效、扫码提前保存凭证、书评正文字段遗漏。
- 没有真实账号登录后的目录、正文、全本缓存、远端增删和精确进度实测；没有绕过阅读权限。尚未完成的能力按上面的限制说明，不以离线桩或 token 成功冒充端到端通过。
- 用户实际短信登录暴露了成功回调关窗异常：主题 `show()` 不返回实例，不能用 `dialog = Input:new{...}:show()`。已拆开创建与显示，回归覆盖同步/异步成功；重新校验已保存会话后补完本地登录状态，不重新发送短信。
