# 新增九个书源代码审计报告

审计基线：`e42555e39b958f786659f13bc0ad4094403d2a81` 加当前未提交的新书源，日期：2026-11-06。

范围：`book.koplugin/source/{dedao,douban,ireader,kuaikan,netease,shuqi,tadu,zhihu,zymk}/`，共 54 个 Lua 文件、4 个 HTML/JS 文件，9,391 行。辅助检查了注册改动、源基类、书架对账、章节下载、目录缓存、数据库身份登记和详情页调用方。未扩大到工作区同时存在的微信读书等其他修改。

按“重复实现 → 单行包装 → 无效防御 → bug”顺序检查。确认 **9 类正确性问题：2 个 P1、7 个 P2**；另列 4 个 P3 维护项。不声称逐行形式化验证，也未用真实账号验证各平台协议。下文发现和行号对应首次审计快照，后续修复状态见本节。

## 分批修复进度（2026-11-06）

1. **得到高风险路径：已修复。** 普通 API 拒绝非 JSON 和无成功码封套；文本 token 只由专用端点处理。分页失败、缺页、解密失败和未结束即超限均返回失败，不再交出半章；合法空白页不误判为解密失败。登录态查询不再用旧配置覆盖新 Cookie。
2. **网易登录：已修复。** 保存并显示输入窗；填写验证码时走短信登录，新密码可同时用于首次注册，纯密码登录保留。
3. **详情与缓存：已修复。** 九源通过 `Store.rememberDetail` 在事务内保存详情、更新时间后才回调，保留书架成员关系、墓碑和本地脏字段；快看、知音漫客后台缓存单独登记章节，不改当前阅读路径；三源领域简介统一为 `intro`。
4. **豆瓣取消与有限清理：已修复。** 多跳请求持有当前活动句柄，取消后不再续跳或回调；正文缓存和即时失败下一帧回调；覆盖同步第一跳后切换异步第二跳的句柄归属。删除掌阅未使用导出和两个漫画源重复目录回退。

回归：九源、真实 SQLite 持久化、宿主身份存储、注册和边界用例共 **14 文件、1,537 断言通过，0 跳过**。新回归覆盖取消、异常响应、分页失败、空白页、登录分派、预览/在架/脏墓碑、写库失败和后台缓存不改变当前路径。补齐章节字段与回调注解、去掉书旗 MD5 单行包装后，全仓 LuaLS 为 **82 → 69 → 39 条诊断，本轮书源及共享改动 0 条**；剩余为范围外模块问题，不代表全仓静态检查全绿。提交前日志在会话目录 `files/source-commits-luals.log`。

**按用户后续要求分批提交，不推送。** 提交范围为九源原始实现与修复、相关测试、共享详情持久化、章节注解、注册和本报告。微信读书、阅读器等其他现有改动保留；两份翻译文件混有其他功能的修改，保持未提交，不擅自挑选其中代码块。新增源源字符串是简体中文，其他语言的补充译文仍在工作区。Cookie 通用解析和漫画下载循环的去重暂不做：协议和生命周期不同，不以修 bug 为由引入新框架。

提交分组：

* `e3409730`：共享详情持久化、得到、网易和书旗及测试。
* `17611249`：豆瓣、掌阅、塔读及测试。
* `bdf8ede7`：快看、知音漫客、知乎及测试。
* 最后一批：九源注册、跨源持久化回归和本报告。

独立模拟器工作目录：`/tmp/moon-sources-a03e395b`。使用提交后的插件快照、独立 KO_HOME 和驱动通道，不读取真实账号配置，不共享可写缓存，不重启现有模拟器；运行时资源只读复用本机构建产物。默认离线启动。

## 需求理解

判断新增书源是否真的能登录、保存完整正文、正确更新本地数据，并遵守已有的取消和缓存契约。

## 核心判断

**值得做，审计时需要修改后再合并。** 最严重的不是风格：得到把坏响应或半章正文当成功，错误会跨过本地持久化边界。以下保留原始发现，修复状态见上。

## 关键问题

* **数据结构：** 登录 Cookie 同时存在内存和设置中，得到在吸收新 Cookie 后用旧设置覆盖内存；漫画文件已经存在，数据库却不知道；详情回包没有进入数据库。
* **复杂度：** 多份近复制的 Cookie、漫画下载和取消编排各自维护状态，成功、取消、落库语义开始分叉。
* **最大风险：** 删除没有得到远端确认却清掉本地墓碑及依附数据；不完整正文被当作完整章节长期缓存。

## 详细发现

### 一、重复实现，优先检查

1. **[P3] Cookie 的解析、排序与序列化重复，生命周期已分叉。** [`dedao/client.lua:43`](book.koplugin/source/dedao/client.lua#L43)、[`tadu/client.lua:26`](book.koplugin/source/tadu/client.lua#L26)、[`douban/client.lua:33`](book.koplugin/source/douban/client.lua#L33)、[`netease/client.lua:31`](book.koplugin/source/netease/client.lua#L31) 都维护 jar、拆分字段、过滤属性、排序输出。得到每次 `loggedIn()` 重载，塔读按需重载，网易另有持久化，豆瓣还区分主机。得到的实际错误见第 7 项。

   最小方案：先修得到覆盖新 Cookie 的顺序；如去重，只抽已经一致的纯解析/序列化，不统一各站登录状态机。已有 `source.cookie_login` 处理的是请求 Cookie/浏览器导入，不应直接拿它冒充 Set-Cookie 解析器。

2. **[P3] 漫画下载与预取已经是第三份近复制，不能继续分头修。** [`kuaikan/chapter.lua:34`](book.koplugin/source/kuaikan/chapter.lua#L34)、[`zymk/chapter.lua:48`](book.koplugin/source/zymk/chapter.lua#L48) 基本沿用 [`copymanga/chapter.lua:41`](book.koplugin/source/copymanga/chapter.lua#L41) 的下载、逐张校验、打包和预取控制流。差异包括请求鉴权、页图获取和知音漫客的文件后缀处理；拷贝漫画保留了同步回调的活动句柄保护，新副本未保留。新增两源的缓存登记问题见第 11 项。

   最小方案：先补缓存登记，不做整套源重构；后续只合并真正相同的预取循环，保留不同协议的图片获取。已有 `source.cbz` 已经收口打包，不要再造 Service/Manager。

### 二、单行包装与空层

3. **[P3] 掌阅导出的 `Mapper.book` 是零调用的纯转发。** [`ireader/mapper.lua:95`](book.koplugin/source/ireader/mapper.lua#L95) 只返回同文件局部 `book(...)`。已搜索插件与测试内的 mapper 引用和调用点，没有此导出函数的调用；内部搜索、详情和书架直接使用局部函数。它不是宿主规定的源接口。

   最小方案：删除这一段未使用导出，保留局部构造器。`Remote:addToShelfAsync` 等把冒号接口映射到协议客户端的方法有真实契约，不算空包装，不建议删除。

### 三、无效防御及吞错

4. **[P3] 两个 `anyToc` 的二次查库并没有提供有效兜底。** [`kuaikan/init.lua:108`](book.koplugin/source/kuaikan/init.lua#L108)、[`zymk/init.lua:104`](book.koplugin/source/zymk/init.lua#L104) 在 `Toc.read` 返回 nil 后，又调用 `BookDB.getToc` 并 `pcall(JSON.decode)`。[`source/toc.lua:95`](book.koplugin/source/toc.lua#L95) 已经做过同样的读取、解码和进程缓存，且当前没有 TTL。

   契约：`Toc.read` 已负责持久化目录的读取和损坏 JSON 隔离。这里失败再解析同一份数据不能恢复故障，反而重复了一套目录合法性标准。最小方案：直接使用 `Toc.read`；必要的损坏数据校验仍留在目录模块。网络 JSON、解密、浏览器输入处的其他类型检查不应当作无效防御删除。

### 四、可能存在的 bug，按影响排序

5. **[P1，已复现] 得到把非 JSON 错页当成删除成功，可能错误撕掉本地墓碑。** [`dedao/client.lua:146-152`](book.koplugin/source/dedao/client.lua#L146) 解码失败或得到非 table 时，直接 `cb(raw, nil, res)`。[`removeAsync:277-285`](book.koplugin/source/dedao/client.lua#L277) 又把任意非空回包当成功；[`Shelf.pushDeletes:109-112`](book.koplugin/source/shelf.lua#L109) 因而调用 `BookDB.remove`。后者会同事务删除进度、笔记等依附数据，并非只更新展示状态。

   触发：删除接口返回 HTTP 200 的 HTML 错页、风控页或无效 JSON。复现注入 `<html>upstream unavailable</html>`，实际回调为 `true, nil`。本地记录被错误确认删除后，远端仍在架的书还可能在下次同步重新出现。

   最小方案：普通 API 必须严格解码和校验成功封套；只有 access-token 端点保留其文本响应协议，不要把特殊响应格式放进全客户端的成功兜底。

   应补测试：HTML/坏 JSON/错误封套删除时返回失败，墓碑和依附表保持；正常删除才清理。当前复现验证了错误确认，依附表删除后果由现有 `Shelf.pushDeletes` 和 `BookDB.remove` 路径确定。

6. **[P1，已复现] 得到下载后续页失败仍返回半章正文，上层会把它缓存成完整章节。** [`dedao/client.lua:371-390`](book.koplugin/source/dedao/client.lua#L371) 在已有 `parts` 后请求失败会回传非 nil 的部分文本；超过 40 轮直接成功，单页 SVG 解密失败也被跳过。源侧 [`dedao/init.lua:106-122`](book.koplugin/source/dedao/init.lua#L106) 只看 `if text`，不再检查同时传回的错误。

   触发：第一批页成功、第二批超时。故障注入得到非空正文加 `"network timeout"`；源随后会转换成无错误的内容载荷，交给通用章节写入。缓存已有文件后不会自动补齐缺页。

   最小方案：没有拿到明确结束标志前，任何请求失败、必要页面解密失败或分页上限都应 `cb(nil, err)`，不能提交 `parts`。不要另加“允许半章”开关。

   应补测试：第二批超时、其中一页解密失败、未结束即达到上限均不得生成可复用章节；完整多批正文才成功。

7. **[P2，已复现] 得到扫码成功返回的新 Cookie 被立刻覆盖，界面可显示成功但实际仍未登录。** [`dedao/client.lua:76-78`](book.koplugin/source/dedao/client.lua#L76) 的 `loggedIn()` 无条件 `Client.load()`。公共回调先 `absorb(res)`，随后在 [`151`](book.koplugin/source/dedao/client.lua#L151) 调用 `loggedIn()`，用磁盘旧 Cookie 重置刚更新的 jar；[`qrPollAsync:217`](book.koplugin/source/dedao/client.lua#L217) 最后保存的也是旧值。

   触发：扫码确认响应通过 Set-Cookie 下发登录会话。故障注入以旧匿名 Cookie 开始，成功响应带新 `session`；回调 `status=1`，但持久化值仍只有旧匿名 Cookie。

   最小方案：状态判断不得有重载 jar 的副作用；初始化/显式重载时读设置，成功响应吸收的新值先保留再持久化。

   应补测试：匿名启动 → 扫码响应 Set-Cookie → 保存 → 下一次认证请求包含新会话，以及服务端轮换 Cookie 的路径。

8. **[P2，已复现] 网易云阅读登录窗口根本打不开：`dialog` 没有声明和赋值。** [`netease/setting.lua:30`](book.koplugin/source/netease/setting.lua#L30) 创建 Input 后没有保存返回值，最后 [`95`](book.koplugin/source/netease/setting.lua#L95) 执行全局 `dialog:show()`。

   触发：点击账号行或调用 `Setting.login()`。主题记录桩复现为索引 nil 的运行错误，Input 只被创建、没有上屏。

   最小方案：把 Input 实例保存为局部 `dialog` 再显示，或者链式 `:show()`；不加 `if dialog` 掩盖漏赋值。

   应补测试：直接调用 `Setting.login`，断言输入窗已显示且无异常。现有 client spec 没调用这个入口。

9. **[P2，已复现] 网易首次短信登录需要设置密码，但界面无法调用对应注册分支。** [`netease/setting.lua:62-90`](book.koplugin/source/netease/setting.lua#L62) 以“密码非空”决定走密码登录。客户端 [`netease/client.lua:344-361`](book.koplugin/source/netease/client.lua#L344) 的首次短信登录则要求同时有验证码和 6–16 位新密码。

   触发：新用户填验证码和新密码，实际调用 `passwordLoginAsync`；不填密码虽能调用短信登录，却在首次登录响应后提示需要设置密码。复现用同一个表单回调填写密码和验证码，密码入口调用 1 次、短信入口 0 次。此问题独立于第 8 项；修好上屏仍会遇到。

   最小方案：提供明确的登录方式，或有验证码时优先短信登录并把密码作为首次注册密码传入。保留老用户纯密码登录。

   应补测试：已有账号密码登录、已有账号短信登录、新用户验证码加新密码三条 UI 到客户端路径。

10. **[P2，已复现/代码路径明确] 九个新源的详情接口只返回数据，违反详情页要求的“源先落库”契约。** 代表位置：[`dedao/init.lua:66`](book.koplugin/source/dedao/init.lua#L66)、[`douban/init.lua:72`](book.koplugin/source/douban/init.lua#L72)、[`ireader/init.lua:97`](book.koplugin/source/ireader/init.lua#L97)、[`tadu/init.lua:96`](book.koplugin/source/tadu/init.lua#L96)。其余五源也没有写书籍展示字段；其中部分只保存目录。

    调用方 [`desktop/detail/init.lua:123-154`](book.koplugin/desktop/detail/init.lua#L123) 明确要求源负责落库，回调后重新 `BookDB.get`，不使用回包里的新字段。因此书架行缺作者/简介时，远端虽然返回详情，界面仍显示旧值，`detail_at` 也可能永远不写，每次打开继续请求。

    复现：给得到客户端返回包含作者和简介的有效详情，源回调收到新简介，数据库/Store 写入次数为 0。九源共同后果为代码路径明确；并未逐源跑真实界面。对照已有 [`fanqie/init.lua:223-237`](book.koplugin/source/fanqie/init.lua#L223)，其成功前会检查 `upsertRemote` 并返回库内结果。

    最小方案：各源在成功回调前按现有模式持久化详情，保留已有 `deleted`/本地脏字段语义，写入失败必须返回错误。不要改核心详情页来迁就这批源。

    应补测试：从缺资料的已入库行出发，调用真实源详情方法后重新读库能看到元数据；故障注入写库失败不可回成功；预览/墓碑不得被意外上架。

11. **[P2，已复现] 快看和知音漫客全本缓存计数成功，但从未登记章节文件。** [`kuaikan/chapter.lua:134-142`](book.koplugin/source/kuaikan/chapter.lua#L134)、[`zymk/chapter.lua:148-156`](book.koplugin/source/zymk/chapter.lua#L148) 只检查 `materializeAsync` 返回路径便增加成功数；对应 `cacheAllChaptersAsync` 直接使用此循环，没有 `ChapterDB.upsert`。

    触发：还未打开过某本漫画，直接全本缓存。两源分别以异步 materialize 桩返回两章有效路径，结果均是缓存成功 2 章、身份登记调用 0 次。宿主 [`BookDB.downloadedClause:906-920`](book.koplugin/book/books_db.lua#L906) 以及 [`Store.isCached:245`](book.koplugin/book/store.lua#L245) 只认 `chapters` 登记，因此已下载筛选、统计和缓存清理入口无法认出这些文件。从桌面逐章打开时会另行登记，不能用那个路径证明全本缓存正确。

    最小方案：每章成功后登记 `path/source_id/stable_id/chapter_idx`，登记成功才计数。只写 `chapters`，不要为此调用会改 `books.path` 的 `Store.touch`，以免后台缓存覆盖当前阅读章。

    应补测试：未打开的漫画全本缓存后能被已下载/缓存查询识别；登记失败计失败；缓存中另一正在阅读章的 `books.path` 不变。

12. **[P2，已复现] 豆瓣多步请求的取消句柄只管第一跳，缓存命中还同步回调。** [`douban/client.lua:256-274`](book.koplugin/source/douban/client.lua#L256)、[`307-323`](book.koplugin/source/douban/client.lua#L307)、[`364-375`](book.koplugin/source/douban/client.lua#L364) 返回第一跳请求，第二跳没有交还取消权；登录 `follow` 跟跳转也有相同形状。另在 [`articleAsync:278-283`](book.koplugin/source/douban/client.lua#L278) 缓存命中直接 `cb(cached)`，返回的 cancel 是空操作。

    触发：详情第一跳完成、第二跳在飞时关闭页面。故障注入确认 cancel 只标记第一跳，第二跳未取消，完成后业务回调仍执行。缓存命中复现也确认回调在取得句柄前已经执行。

    错误语义：违背 `SourceBase`“取消后不回调、立即结果也下一帧回调”的现有契约；外层串行链还可能被同步命中返回的旧句柄覆盖，留下取消不了的后续请求。部分 UI 有 closed/generation 检查，只挡结果，不等于取消了活动 IO。

    最小方案：每次多步操作持有自己的 `cancelled/active`，跳转和第二跳更新活动句柄；缓存命中用 `SourceBase.defer`。同步命中造成的嵌套赋值覆盖也要一起消除，不新增通用 Handle 层。

    应补测试：第一跳前、两跳之间、第二跳期间取消均不再请求/回调；正文缓存命中可以在下一帧前取消；扫码跟跳转时取消能停止当前跳。

13. **[P2，已复现/代码路径明确] 快看、知音漫客、知乎把书籍简介写成 `description`，领域和数据库只认 `intro`。** [`kuaikan/mapper.lua:50`](book.koplugin/source/kuaikan/mapper.lua#L50)、[`zymk/mapper.lua:52`](book.koplugin/source/zymk/mapper.lua#L52)、[`zymk/mapper.lua:71`](book.koplugin/source/zymk/mapper.lua#L71)、[`zhihu/mapper.lua:67`](book.koplugin/source/zhihu/mapper.lua#L67) 都输出了错误键。

    触发：源返回非空简介。知乎搜索映射复现为 `description="intro"`、`intro=nil`；其余两源同形。[`Store.rememberMany:41`](book.koplugin/book/store.lua#L41) 和数据库写入读取的是 `row.intro`，不会自动映射 `description`。即使补好第 10 项落库，这三源的简介仍会丢。

    最小方案：只修改领域对象输出键为 `intro`；远端原始响应里的 `description` 保持不变，不给数据库增加别名字段。

    应补测试：源映射后简介经真实入库和重读仍在，而不是像现有知音漫客测试那样断言错误的 `.description`。

## Linus 式方案

1. 先修得到的成功判定：删除必须确认远端成功，正文必须完整；用失败路径测试钉住墓碑和章节文件。
2. 修登录和本地数据契约：Cookie 不回滚、网易表单可打开且分派正确、详情先落库、漫画登记章节、简介统一用 `intro`。
3. 修豆瓣的操作所有权和异步回调，再做有限去重。四个 P3 不值得单独搞架构重构。

## 代码检查

**语法：** ⚠️ LuaLS 全仓 Warning 级检查不通过，82 条问题，包含网易未定义的 `dialog`、新源类型和注解问题，也包含范围外问题；不是纯语法错误计数。两个验证码 JS 的 `node --check` 通过。

**逻辑：** 审计时 ❌，发现失败当成功、登录态回滚和本地持久化缺环；上述路径现已修复并有离线回归。

**兼容性：** 修复保留源 id、模块路径、设置键、书籍身份、墓碑协议和取消后不回调的契约；详情先落库，不改宿主详情页接口。

### 首次审计验证记录与限制

* 已有测试：`./tests/run.sh tests/source/{dedao,douban,ireader,kuaikan,netease,shuqi,tadu,zhihu,zymk}/*_spec.lua tests/source/registry_external_spec.lua tests/meta_spec.lua tests/feature_boundary_spec.lua`，**12 文件通过，1,057 断言**。
* 故障注入：会话目录 `files/source_audit_repro.lua`，通过同一 runner 执行，**1 文件通过，33 断言**。脚本断言的是当前缺陷确实存在，不是修复回归已通过；未加入仓库测试树。
* 注入覆盖：得到新 Cookie 丢失、坏响应删除确认、后续页超时；网易登录上屏和模式分派；豆瓣活动请求取消及缓存同步回调；两漫画源缓存未登记；知乎简介错键；得到详情无落库。也排除了“网易缺 `wordCount` 必然导致算术错误”的猜测，未将它列为问题。
* 静态检查：`lua-language-server --check="$PWD" --configpath="$PWD/.luarc.json" --checklevel=Warning`，完成后退出 1，**82 条诊断**；完整输出保存在会话目录 `files/source-audit-luals.log`。未因本次只交报告而顺手修改其他模块。
* 两个验证码 JS：`node --check` 通过。未做真实短信、扫码和远端付费账号测试，未部署 Kindle 或重启用户模拟器。
* 初次测试误传目录，runner 拒绝读取；已改用明确的 `*_spec.lua` 文件参数重跑。此命令用法失败不是书源业务失败。

## 过度设计

**🟡 可接受。** 源模块划分本身不需要推倒重来；问题是复制状态机时丢了契约，不是缺少更多抽象。

## 冗余

* **无意义函数：** 掌阅 `Mapper.book` 导出，插件及测试中零调用。
* **无意义类：** 未发现足以要求删除的类。
* **无意义抽象：** 未发现应当新建或整体拆除的转发层；源接口适配保留。
* **无意义判空：** 两个 `anyToc` 的重复 fallback；外部输入校验保留。
* **无意义转换：** 未单列，不能把网络字段规范化一概删除。
* **无意义异常处理：** 得到 JSON 解码失败转成功，不是恢复策略，见第 5 项。
* **可删除代码：** 零调用 mapper 导出、重复目录回退；去重限于证据明确的纯逻辑。

## 致命问题

**成功不等于持久化正确。** 得到远端删除未确认就可能触发本地物理删除，正文没下完整就可能成为可复用缓存。这两项优先于所有包装和格式问题。

## 最终结论

**9 类正确性问题已修复并补回归，按四批提交。** 原始 client spec 全绿不足以证明登录 UI、数据库和取消链路正确，新增用例已覆盖这些边界；仍未验证真实账号的远端协议。提交含九源原始实现及必要接线，不纳入其他现有业务改动，不推送。
