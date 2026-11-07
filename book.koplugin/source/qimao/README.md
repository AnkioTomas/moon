# 七猫小说

## 能力与边界

| 功能 | 当前实现 |
|---|---|
| 登录 | 设备端手机号 + 短信验证码；发送验证码前由远程网页桥接数美滑块。也可导入浏览器登录态中的 token，或手动粘贴 token。 |
| 书架 | 登录后分页拉取远端书架；本地新增和删除先在月读生效，再由书架同步上行。 |
| 搜索与发现 | 关键词搜索只取第一页；书库浏览支持频道、分类、子分类、排序、字数、更新时间和完结状态筛选，并按需继续拉页。 |
| 目录与正文 | 按章读取目录和正文；目录写入本地缓存，正文按章缓存。仅已缓存章节可离线阅读。 |
| 进度 | 以章节为单位读取和推送书架上的最近阅读章节；不支持章内位置同步。 |
| 笔记、统计、评论 | 插件未实现笔记、阅读统计、书评、章评、段评和回复同步；这不代表七猫所有协议都没有对应接口。 |

正文接口按服务端返回处理。付费状态、未购买错误和购买内容均未做实测；插件不会尝试绕过购买或站点权限。

**账号切换限制：** 当前本地书籍及待同步改动没有绑定七猫的稳定账号 ID。切换 token 后，旧账号留下的待新增、删除墓碑或进度可能随新 token 上行。切换账号前应先确认没有待同步改动；账号隔离尚未实现，不能视为安全支持的换号流程。

## 协议

账号请求与公开书城请求分开：登录及书架使用网页账号 token；分类书城使用匿名 PC Web 接口；搜索、目录和正文当前使用无账号的 App 风格接口。书源请求不读取或上传浏览器 Cookie。

| 用途 | 请求 | 关键参数 / 行为 | 登录 |
|---|---|---|---|
| 发送短信码 | `POST xiaoshuo.wtzw.com/api/pc/v1/login/send-code` | 表单 `phone`、滑块凭据 `rid` | 否 |
| 手机号登录 | `POST xiaoshuo.wtzw.com/api/pc/v1/login/index` | 表单 `phone`、`code`；成功响应需含 `data.token` | 否 |
| 校验 token | `POST xiaoshuo.wtzw.com/api/pc/v1/user/get-user-info` | 表单请求，`Authorization` 头携带 token | 是 |
| 读取书架 | `POST api-bs.wtzw.com/pcapi/v1/user/local` | `page`、`size=50`，依 `meta.total_pages` 翻页 | 是 |
| 新增 / 删除 / 更新书架 | `POST api-bs.wtzw.com/pcapi/v2/user/sync` | 表单 `items` 为 JSON；`push_type=1` 新增或更新，`2` 删除 | 是 |
| 书库筛选项 | `GET www.qimao.com/api/classify/select-option` | 返回频道、排序、分类树及字数、更新时间、完结状态选项 | 否 |
| 书库列表 | `GET www.qimao.com/api/classify/book-list` | `channel`、`category1`、`category2`、`order`、`words`、`update_time`、`is_over`、`page`；`page_data` 提供分页信息，每页当前为 15 本 | 否 |
| 关键词搜索 | `GET api-bc.wtzw.com/search/v1/words` | `wd`、`page` 等参数；当前源只请求第 1 页 | 否 |
| 目录 | `GET api-ks.wtzw.com/api/v1/chapter/chapter-list` | `id`、`chapter_ver`；章节按 `chapter_sort` 排序，章节 ID 为 `id` | 否 |
| 正文 | `GET api-ks.wtzw.com/api/v1/chapter/content` | `id`、`chapterId`；当前实现解码 Base64 后按 AES-128-CBC 解密 | 否 |

App 风格接口的查询参数和请求头按当前代码签名；响应通常为 `{ data = ... }`，错误为 `{ errors = { code, title } }`（HTTP 状态可能仍为 200）。网页账号接口按 `errors.code` / `errors.title` 判错。滑块页面只把 `rid` 交回设备；手机号与短信码留在设备，不发送给滑块网页。网页使用数美脚本，只有在用户主动发起短信登录时才加载。

## 本地数据与同步

- 书架新增、删除和进度先写本地；联网后由源的书架 / 进度同步推送。远端失败不会回滚本地操作，失败项保留待重试。
- 删除遵循公共墓碑流程：本地先隐藏书籍，之后同步调用书架接口；只有远端请求被接受后才清除墓碑。当前没有远端读回确认，因此不据此声称远端删除已实测成功。
- 开书时从远端书架行读取 `latest_read_chapter_id`，再映射到本地目录序号；关书时以 `push_type=1` 更新章节 ID、标题和序号。段内偏移不作为可同步进度。
- 未登录时本地阅读和缓存仍可用；账号书架及进度同步不可用。未缓存正文需要联网。
- 目录从本地缓存读取；缺少缓存时联网获取。正文按章缓存，缓存失败会返回错误，不会把失败正文登记为成功缓存。

## 核对记录与未验证项

- 核对日期：2026-11-07。
- 本次匿名读取了七猫 PC Web 的分类选项与列表接口，确认分类树、分页字段以及 `words`、`update_time`、`is_over` 筛选项；在浏览器检查公开书籍页时观察到目录请求 `GET /qimaoapi/api/book/chapter-list?book_id=...`。当前插件的目录仍走上表中的 App 风格接口，PC Web 正文请求尚未研究，不能把它描述为已完成 Web 协议迁移。
- 本次离线用例覆盖 token / 短信登录解析、书架映射与分类筛选，以及多阶段进度请求的取消；未使用真实账号登录，也未执行短信发送、书架改动、远端进度写入或读回。
- 未实测 App 风格接口的正文解密、付费章节错误、登录失效重定向、真实账号切换、远端删除确认及设备 / 模拟器阅读流程。以上均不应视作端到端通过。
