# 番茄小说书源

## 能力与边界

| 功能 | 当前实现 | 2026-11-08 本轮核对 |
| --- | --- | --- |
| 登录 | 番茄小说 App / 抖音扫码；成功取得 `sessionid` 后保存，取消不覆盖旧登录 | 未进行手机扫码确认；没有密码登录或手动 Cookie 导入界面 |
| 书架 | 拉取书架与分组；本地新增、删除由同步发送 add / delete 请求 | 离线用例通过，未用真实账号增删或回读确认；不能据此承诺远端删除已验证 |
| 搜索 | 免登录 App 搜索，当前只取第一页 | 协议与离线用例核对，未实测后续页 |
| 发现 | 官网男/女频阅读榜、新书榜、动态分类；只取榜单页面首屏 10 本 | 官网存在独立书库与分页接口；插件尚未接入完整书库、排序、状态、字数筛选和后续页 |
| 详情 / 目录 | 官网详情；目录缓存、刷新，按章节 ID 保持顺序 | 匿名获取详情与 1496 章目录 |
| 正文 | App reading 协议注册本机设备、获取密钥、解密正文；漫画另存 CBZ | 一章免费正文下载成功，断网复用本地章节；未验证漫画、已购或受限内容 |
| 段评 | App commentapi：段落计数、评论页、回复页；按正文 `blk p_idx` 定位 | 67 个热点，66 个定位到正文；两页各 20 条，游标 20 → 40；回复首页 20 条 |
| 章评 / 书评 | 未提供独立列表入口 | 官网阅读页与公开脚本未找到可验证的 Web 段评 / 章评接口；这不代表 App 没有。统计中的未定位条目不强行挂到其它段落 |
| 进度 | 官网章节级双向同步；不支持精确的云端章内位置 | 离线映射用例通过，未写真实远端进度或回读确认 |
| 笔记 / 统计 | 无远端笔记、统计接口实现；本地阅读记录由宿主管理 | 不宣称支持远端同步 |
| 离线 | 已缓存目录、章节、段评可用；无缓存的网络内容明确失败 | 断网读取 20 条缓存段评、重开同一章成功 |

## 段评与 emoji

番茄返回的 `[笑]`、`[哭]`、`[吃瓜]` 等是文本标记，不是 Unicode emoji。已知标记映射成语义对应的 emoji 图片，**不是番茄官方表情原图**；未收录标记以及 `[因果]` 这类书中术语仍是文字，不猜地址、不吞正文。

评论、回复、回复页引用与长评论全文共用主题行内图片。常见 Unicode emoji 支持肤色、ZWJ 组合、国旗和键帽，不要求额外安装 emoji 字体。图片采用 [Twemoji 16](https://github.com/jdecked/twemoji) PNG，经 jsDelivr 下载，沿用主题图片磁盘缓存；Twemoji 图形版权归 Twitter, Inc. 及贡献者，许可为 [CC-BY 4.0](https://creativecommons.org/licenses/by/4.0/)。未使用番茄私有表情目录，也不附带账号 Cookie。

原评论文字不改写，复制、引用和缓存保留原文。首次显示未缓存的表情图片需要联网；离线缺图只能使用文字控件的占位回退，不能承诺所有 emoji 字形都可见。旧段评缓存不清空，旧缓存缺少表情映射时仍显示原标记，联网更新后取得映射。

坏段落统计、缺失评论列表和“首页空列表但总数非零”均报错，不覆盖缓存成无评论。注册设备与评论请求分阶段可取消，取消后忽略迟到回调；同步测试桩也不会把当前请求句柄覆盖成已完成的注册句柄。

## 协议概览

这是**电脑 Web 与 App 协议混用**，不是纯 Web 书源。账号请求使用 `fanqienovel.com` 会话；正文与段评使用独立设备身份及签名，不转发电脑账号 Cookie。

| 用途 | 方法 / 主域 / 路径 | 主要字段与语义 |
| --- | --- | --- |
| 扫码 | GET `fanqienovel.com/passport/web/get_qrcode/`、`check_qrconnect/` | 匿名登录会话，扫码状态与最终 `sessionid`；不缓存敏感响应 |
| 书架 | GET `fanqienovel.com/reading/bookapi/bookshelf/info/v:version/` | 登录必需；`book_shelf_info`、书号、分组及加入/打开时间 |
| 在架详情补全 | POST `fanqienovel.com/api/bookshelf/multidetail` | `books`；主详情查无此书时补全在架书名，不因无详情丢掉成员 |
| 加架 / 删架 | POST `fanqienovel.com/reading/bookapi/bookshelf/{add,delete}/v:version` | 登录必需，`identify_data`；现有实现判断 `code=0`，本轮未验证实际写入结果 |
| 详情 / 目录 | GET `fanqienovel.com/api/book/info`、`api/reader/directory/detail` | `bookId`；匿名可用，详情 / 章节数组 |
| 搜索 | GET `novel.snssdk.com/api/novel/channel/homepage/search/search/v1/` | `aid`、`offset`、`q`；App UA，不带 Cookie |
| 榜单 | GET `fanqienovel.com/rank/<频道>_<榜单>_<分类>` | 页面内嵌状态，动态分类；当前不调用签名分页接口 |
| 设备注册 | POST `log.snssdk.com/service/2/device_register/` | 本机生成画像，返回设备 / 安装身份；注册被网络拦截时明确报错 |
| 正文 | POST / GET `api5-normal-sinfonlinec.fqnovel.com/reading/crypt/registerkey`、`reading/reader/batch_full/v` | 设备签名、书号、章节 ID、密钥；空响应、非零业务码、解密失败均失败，不写成功缓存 |
| 段落统计 | GET `api5-normal-sinfonlinec.fqnovel.com/novel/commentapi/idea/list/<章节 ID>/v1/` | 无 body；`data.data[段序].count`，与正文 `blk p_idx` 对应 |
| 段评列表 | POST `api5-normal-sinfonlinec.fqnovel.com/novel/commentapi/comment/list/<章节 ID>/v1/` | `comment_source=2`、`group_type=15`、`business_param.book_id/para_index`；`data_list`、`common_list_info` |
| 回复列表 | POST `api5-normal-sinfonlinec.fqnovel.com/novel/commentapi/reply/list/<评论 ID>/v1/` | `comment_source=5`；`reply_list`、`comment_list_info`，游标以字符串传递 |
| 进度读写 | GET / POST `fanqienovel.com/api/reader/book/progress`、`update_progress` | 登录必需；章节 ID、零起始 `index`；`read_progress` 不是章内万分比 |

段评及回复按服务端游标分页；没有更多数据或游标不前进就停止。图片独立于评论正文，用户 HEIC 配图换成同图的 WebP 缩略图，不影响文字评论。

## 本地与账号行为

本地库与文件是唯一真相。书架操作先在本地生效并标脏；删除先清本地文件、留墓碑，再由同步推远端删除，确认后才移除本地记录。网络失败保留脏状态 / 墓碑待重试，删除入口不先请求远端。

本地缓存不因本轮表情升级强制失效。在线段评取得最新列表并更新缓存；离线热点只保留已有首页评论缓存的段落，未缓存内容立即提示未联网。回复页目前不单独缓存。

**换账号仍有边界风险：**当前扫码成功直接替换 Cookie，没有稳定账号 ID 比较与直接换号的数据隔离。本轮没有改动登录、启用新上行能力或清理真实账号数据。需要换号时先使用已有“退出登录”入口，确认清除本设备该源书架、进度、笔记及缓存，再登录新账号；未同步记录也会被清除，不能静默执行。退出登录先停任务、清凭证，再清本地记录，不向远端发送删书。

## 实测与未验证项

2026-11-08 使用独立空数据模拟器，未复制用户 Cookie、账号或书架，未改远端书架、进度、评论、点赞。官网书库 / 阅读器入口与公开脚本经浏览器核对；匿名 App 段评、回复、免费正文和缓存经实际插件调用核对。段评首页 20 条中 9 条包含已知表情，回复首页 20 条中 4 条包含已知表情；去敏样例截图确认文本、表情与组合 emoji 排版正常。

29 个针对番茄、共用段评和其它源兼容性的 spec 通过，共 1052 条断言；本轮文件使用仓库原诊断规则与绝对依赖路径做 LuaLS 定向检查，无问题。全仓诊断先发现无关 `features/battery/probe.lua` 既有告警，未完成全仓扫描，不宣称全仓零告警。

手机扫码确认、验证码、账号失效 / 换号真实流程、远端增删及进度回读、付费权限、漫画和整本缓存未进行实测。现有登录模块还有敏感响应日志需要另行收口；本轮未运行会输出这些内容的真实扫码流程。书城仍只有榜单首屏，不能当作完整书库；这些限制不是段评 emoji 实现的能力承诺。
