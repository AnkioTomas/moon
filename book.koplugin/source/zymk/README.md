# 知音漫客（zymk）

本源使用官方 Web 协议，不使用 App 私有接口。账号与公开阅读分离：
登录提供短信验证码、密码和手动 Cookie 导入，成功后只保存服务端校验的 `type/openid`，
不保存密码、短信码或临时 `appToken`；
公开阅读、书城和评论不发送账号凭证。
漫画身份始终是知音漫客 ID；目录中的 `uid` 仍是 `看漫画 ID/chapter_newid`，
已有目录版本和 CBZ 路径保持兼容。

## 能力与边界

| 功能 | 当前实现 |
| --- | --- |
| 搜索 | 官网搜索，按 `total_page` 聚合，最多约 200 本，重复身份去重，中间页失败整体报错 |
| 书城 | 官网完整 `allComic` 分类库；动态题材、进度、受众、媒体标签；新更、人气、打赏、评分、月票排序；默认最多 60 本供 UI 分页 |
| 详情、目录、阅读 | 知音漫客详情 → 官方看漫画重定向 → 目录；免费页图下载为 CBZ，由 KOReader 阅读 |
| 离线 | 已落盘的目录、CBZ 和本地进度可离线重开；未缓存内容断网立即报错 |
| 缓存 | 复用月读的章节预取、全本／范围缓存和后台任务；下载失败不生成成功 CBZ，可以重试 |
| 书评 | 公共整书评论列表，详情页展示最新第一页；传输可取后续页，当前公共书评窗口没有翻页入口 |
| 章评、段评 | 本次 Web 协议未找到可验证接口，不把整书评论重复挂到章节或图片上 |
| 回复、发评、点赞 | 尚未接入；不代用户发评、点赞或删除评论 |
| 登录 | 短信验证码、密码、手动 Cookie 导入；短信触发点字验证时由用户按官网示例点选；必须经 `/apinew/getuserinfo/` 兑换或校验账号。微信登录已移除，不提供浏览器扩展回传或 App 扫码入口 |
| 已购／VIP | 尚未实现账号权限；标价章节提示“本章未购买”，不能声称可读取用户已购内容；不绕过购买 |
| 远端书架 | 登录后拉取完整收藏并对账；未接入收藏新增／删除上行，不承诺双向同步 |
| 远端进度、笔记、统计 | 未启用；进度写入试验无法回读确认，本地记录保留，不谎标已同步 |

官网登录页是 `https://www.zymk.cn/login.htm`，实际显示手机验证码、密码、
知音漫客 App 扫码及第三方登录。此前仅查看首页、未找到入口的结论不充分。
官网公共脚本还包含 `getuserrecord`（收藏和阅读记录）、
`get_purchased_chapters` 等账号代码；收藏拉取已接入，成员上行和已购权限尚未接入，
不是“官网没有书架增删或已购接口”。
书城没有经验证的价格筛选，不能用章节价格伪造整书资费。

## 协议概览

下表的公开请求不附带账号凭证；账号接口只向 `www.zymk.cn` 提交。
知音漫客和看漫画成功码为 `status=0`；
评论服务实测成功码是 **`status=1, msg="ok"`**，不能套用前两者的判断。

| 用途 | 方法、域名及路径 | 参数／响应 |
| --- | --- | --- |
| 发送短信／图形验证码 | POST `www.zymk.cn/apinew/sendsms/` | `mobile`, `service=zymk`, `refresh=0/1`, `imgCode`；`status=1031/1028` 返回 `Image/Width/Height/Content` 点字题；用户按顺序点两处后提交 `appId=11,fontPoints,userIdentifier=<mobile>,verificaType=2`；`status=0` 才算短信已发送 |
| 短信登录 | POST `www.zymk.cn/apinew/mobilevclogin/` | `mobile`, `vcode`；`status=0` 返回 `data.appToken`，仅用于下一步兑换 |
| 密码登录 | POST `www.zymk.cn/userapi/login/` | `identity`, `pwd`（密码保持原值）；`status=0` 返回 `data.appToken`，仅用于下一步兑换 |
| Cookie 导入 | 本地解析 | 取官网登录后请求头中的完整 Cookie，解析官网 `user` Cookie 的 `type/openid`；不凭 Cookie 的存在性判登录成功，不保存整份浏览器 Cookie |
| 账号兑换／校验 | POST `www.zymk.cn/apinew/getuserinfo/` | 密码／短信：`type=mkxq`, `token=<appToken>`；Cookie：`type`, `openid`；必须返回非匿名 `data.type/openid` 才保存，Cookie 校验还必须匹配提交的身份。匿名缺参数实测返回 `status=1, msg="type or token not found"` |
| 收藏拉取 | POST `www.zymk.cn/apinew/getuserrecord/` | `type`, `openid`；`status=0, data.ubook[]`，收藏身份为 `comic_id`，标题为 `comic_name`，`addtime` 从毫秒转秒；完整快照无分页参数。不传 `client/sync`，不合并浏览器本地收藏或历史 |
| 搜索 | GET `www.zymk.cn/apinew/getsortlist/` | `key`, `page`；`data.page.comic_list`, `total_page` |
| 分类标签 | GET `www.zymk.cn/sort/all.html` | `.filter` 的分组标题与 `data-tag`，不硬编码分类 ID |
| 完整分类库 | GET `www.zymk.cn/apinew/allComic/` | `data[]`：`comic_id`, `comic_name`, `class_idlist`, `update_time`, `total_click`, `dashang`, `pingfen`, `zongpiao`；官网也是本地筛选这份完整数据，不存在该列表的服务端分页参数 |
| 详情 | GET `www.zymk.cn/<漫画 ID>/` | Open Graph 元信息与相对章节链接，实体按 XML 解码 |
| 阅读重定向 | GET `www.zymk.cn/<漫画 ID>/<章节文件>.html` | 301 等重定向的 `Location` 必须指向 `www.kanman.com/<ID>/` |
| 目录 | GET `www.kanman.com/api/getchapterlist` | `comic_id`；`data[]` 按 `order_num` 升序，付费标记取 `price` |
| 页图 | GET `www.kanman.com/api/getchapterinfov2` | `product_id=1`, `productname=kmh`, `platformname=pc`, `comic_id`, `chapter_newid`, `isWebp=0`, `quality=middle`；`data.current_chapter.chapter_img_list` |
| 书评 | GET `community-hots.321mh.com/comment/newgets` | `appid/appId=11`, `ssid=<知音漫客 ID>`, `ssidtype/ssidType=0`, `page`, `pagesize=20`, `filter=1`, `contenttype=0`, `relateid=0`, `fatherid=0`；`data[]` 必须归属所请求的整书 |
| 官网评论计数（研究用） | GET `community-hots.321mh.com/comment/count` | 同一整书归属，`commentType=0`；本源不依赖它推测列表精确页数 |

不同页面的 ID 不可混用：书评用知音漫客 ID，页图用重定向得到的看漫画 ID。
评论列表满 20 条只标记可能还有下一页；`pages` 是提示“还有更多”的下界，
不是准确总页数。网络失败、坏 JSON、坏归属或错误成功码显式报错，不伪装为空列表。
没有页图且声明价格或会员时提示未购买；错误响应不缓存成章节。

## 本地与同步

书城加入、阅读进度和统计沿月读本地 sqlite／文件机制立即生效。
`shelf_push=false`；登录后书架同步拉取收藏，匿名或 `dirty_only` 时仍返回 skipped。
复用 `source.shelf` 对账，保护本地脏书和删除墓碑，空快照不清空本地书库；
网络失败、坏收藏响应、取消和换号不写入快照。
没有远端推送方法，因此待同步进度／笔记／统计不会发送到官网。

删除沿 `SourceBase:deleteBookAsync` 清本地缓存并标墓碑；没有远端确认删除的实现，
墓碑保留，不承诺已从官网收藏移除。账号保存到 `settings/zymk.lua`；
登录失败、取消、网络失败及旧请求迟到不覆盖原账号。不同 `type/openid` 要先退出旧账号：
复用月读现有退出确认，明确清除这个源的本地书架、进度、笔记和缓存，不发远端删除。
官网身份是否跨所有登录方式稳定尚未实测；身份不同保守视为换号，不自动合并。
未登录也能使用公开阅读，`configured=true` 不表示已登录。尚未开启任何账号上行。

## 本次核对（2026-11-07）

公开官网核对：分类库 115 本，动态筛选 4 组；《长相思》重定向至看漫画，
目录 33 话，免费序章页图接口返回 14 张。评论服务《凤逆天下》第一页和第二页
均返回 20 条整书评论；官网显示 0 的计数不能作为“没有评论”的依据，
独立匿名计数请求实际返回正数。

独立联网模拟器实测（全新 home，不借用真实账号或数据）：

| 项目 | 结果 |
| --- | --- |
| 书城 | 默认 60 本，8 本／页，共 8 页；第 8 页 4 本；热血筛选 51 本；封面与两行筛选正常 |
| 搜索、详情、目录 | 搜索《长相思》1 个结果；详情与 33 话目录成功落盘 |
| 实际阅读 | 免费序章生成 CBZ 并由 KOReader 打开，14 页 |
| 书评 | 源接口第一页 20 条，第二页 20 条，未接成章评／段评 |
| 全本缓存 | 现有 `kind=cache` 后台任务完成 33/33 话，失败 0；暂停后由已有任务机制续跑 |
| 离线阅读 | 断网重开首章成功；经真实阅读会话切到下一章（4 页）；全本缓存后末章也能离线开，关书后按本地进度重开同章 |
| 离线未缓存 | 全本缓存完成前，尚未缓存的末章立即提示网络不可用 |
| 本地增删／同步边界（匿名阶段） | 独立沙箱新增测试条目、本地删除后 `deleted=1` 墓碑保留；匿名书架同步返回 skipped |
| 恢复联网 | 还原原始网络方法后，禁用缓存的真实 HTTP 请求成功 |
| 离线回归与静态检查 | 本源 6 个 spec、148 个断言通过；本源 7 个 Lua 文件在完整依赖解析下 LuaLS 无问题 |

上一轮公开阅读的测试沙箱、阅读缓存及自己创建的浏览器页在验证后清理；
本轮独立账号验证环境保留供用户操作，不使用真实配置目录。

本轮补充核对官方 `/login.htm`：存在真实登录界面，公开脚本明确短信发送、
点字验证、短信码／密码提交、`appToken` 兑换和 `user` Cookie 的字段。
最终保留短信验证码、密码与 Cookie 三种方式；微信登录按用户要求移除。
点字窗口用离线布局样本验证：原图 320×320，
四分之一／二分之一位置转换为 (80,80)／(160,160)，这不等于官网真实点字提交成功。
登录阶段本源 7 个 spec、226 个断言通过。
账号输入、取消、失败保留旧账号、不同账号拒绝覆盖、Cookie 归属和短信重发冷却
均有离线回归。随后用户在独立环境完成登录，持久账号可用于真实收藏拉取；
没有分别实测三种登录方式的成功链路，不能用桩响应宣称它们全部实测通过。

真实短信发送、点字提交、三种登录方式分别成功、用户已购内容及远端书架增删仍未完成实测。
没有购买、充值、发评、点赞、远端删除或修改官网收藏。

### 收藏与进度补充验证

独立模拟器的持久登录可用。纯读收藏接口成功返回 1 本，实际对账
`pulled=1, pushed=0, skipped=false`，本地书库及图书馆显示 1 本。

用户明确授权以该收藏书第 1 话试验阅读历史写入。研究发现知音漫客旧数字章节 ID
与看漫画数字章节 ID 不同，标题和目录数量也可能不同；旧章节的官方重定向可以精确匹配
看漫画 `comic_id/chapter_newid`，不能凭标题、序号或直接复用数字 ID 推进度。

| 进度协议（仅研究，未交付） | 真实结果 |
| --- | --- |
| POST `www.zymk.cn/apinew/getuserrecord/`，`client=web, sync.user_read[]`：`comic_id, chapter_id, readtime, readpage` | 多种官网字段形态均 HTTP 200、`status=0`，随后纯读仍未返回对应历史，不能确认保存 |
| 官方现用阅读网页 POST `adduserread.321mh.com/app_api/v5/adduserread`，临时 `userauth`、`type/openid`、看漫画书／章 ID、`read_time/chapter_page`，`product_id=1, productname=kmh, platformname=pc` | HTTP 200、`status=0`；随后官方 GET `www.kanman.com/api/getuserrecord` 回读 HTTP 500，无法核对章节或页位置 |

后一条虽路径含 `app_api`，确由官方 PC 阅读网页调用；这里只记录公开协议，
未保存临时授权码，也未将它作为默认 App 回退接入。官方网页成功读回的对照未完成，
不能把 HTTP 500 的原因断言为已确认的官网故障。
已撤下未验证的进度读写方法及映射辅助代码，不启用自动推送。
授权试验可能留下官网第 1 话历史，是否保存无法确认；本地试验进度仍是脏记录，
没有标为已同步，也没有修改收藏。

收敛后的本源 8 个 spec、270 个断言通过；与公共书架、元信息和文字控件检查合跑
11 个 spec、724 个断言通过，10 个源 Lua 文件在完整依赖解析下 LuaLS 无问题。
此前全库运行有两项失败：既有国际化残留键检查，以及本任务验证码说明缺少底色声明；
后者已修复并通过定向检查，全库未重新运行，不宣称全库全绿。

微信历史实测：扫码和手机确认完成（404 → 405），随后账号兑换立即 HTTP 500；
对齐官网 AJAX 请求头后仍失败，未获得有效账号，因此已删除相关入口、协议和轮询代码。
未完成官方网页成功登录的对照，故不把网站故障原因写成已确认结论。
