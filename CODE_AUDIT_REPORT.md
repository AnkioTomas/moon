# 时段提交代码审计报告

**后续修复状态：** 下文保留审计时的基线与发现；编号 1–10 已在后续修复中处理，新增了换库失败、冷目录决议、心跳门禁、不完整书架与负缓存回归。修复后的全量离线测试为 688 passed、0 failed。全仓 LuaLS 尚有既有诊断，未宣称全仓静态检查通过。

审计时间窗口：**北京时间 2026-11-08 17:00–23:11:36**，终点固定为请求发起时的提交，不随审计耗时延长。

审计基线：`d2c154011d435a38e29a839d11df76a1cfbb0060` → `5b0c24d5436ddca0643010d00a9953d440558e1d`。范围内共 **36 个可达提交、27 个主线提交**，包括合并引入的改动；净差异 **188 个文件，新增 4347 行、删除 1156 行**。

主要审查交付目录 `book.koplugin/` 的变更及必要调用链：116 个变更文件，其中 115 个 Lua 文件；这些文件在终点提交合计 38160 行，插件净差异新增 2328 行、删除 687 行。另检查相关测试、CI 与设备工具改动。重点数据流包括换号/换库、目录缓存与异步恢复、阅读进度决议、书架对账、详情页续读目标、本地目录设置及电池统计。译文做关联抽查，不声称所有文件均经逐行形式化验证。

**本次只生成报告，不修改业务代码，不提交。** 审计期间出现 `source/wechat/chapter.lua` 及其测试的未提交外部改动，未纳入结论、未修改或回退；全量测试和六组复现均已在独立的固定提交快照重跑。

## 需求理解

审查今天下午 5 点起到请求发起时提交的代码，找出重复实现、单行包装、无效防御和真实行为缺陷，并给出最小兼容修法。

## 核心判断

**值得做，结论是需要修改。** 发现 1 项 P1、5 项 P2、4 项 P3。主要问题不是代码难看，而是失败仍激活新书库、目录尚未恢复就提交进度决议，以及把不完整远端书架当成完整快照。

六项行为问题均有隔离复现；其中 Kavita 心跳是**既有发送路径未接入本次新增门禁**，不是把未改代码冒充新增实现。远端数据污染/覆盖的后果依据调用链判断，未向真实服务发破坏性请求。

## 关键问题

* **数据结构：** 书籍身份只有源 ID 与 stable ID，没有服务器/账号维度；换库必须可靠清掉旧记录。目录的磁盘缓存、异步读取和阅读会话快照也不能被视作同时就绪。
* **复杂度：** 进度决议已有统一状态，但仍存在绕过它的源内发送入口；详情页内部的 `false` 缓存哨兵又在接口边界丢失。
* **最大风险：** 清库失败后旧脏记录仍在，新凭据已经生效。后续同步可能把旧库的墓碑、进度或笔记发到新库，而界面先告诉用户保存成功。

## 详细发现

### 一、重复实现，优先检查

**未发现需要新增抽象层来解决的、达到 Rule of Three 的重复实现。**

本时段已经把多个阅文源的账号提交收口到 [`source/cookie_login.lua:135`](book.koplugin/source/cookie_login.lua#L135)，也删除了多个源自行读取旧目录 JSON 的路径，这是正确方向。

`BookDB.remove`、整源清理和单本强制清理的墓碑要求、事务及事件语义不同，不能因形状相似就硬合并。公开文档门面、源接口适配和生命周期转发也不算无意义包装。

### 二、单行包装与空层

1. **[P3] `anyToc` 删除兼容逻辑后只剩转发。** [`source/copymanga/init.lua:236`](book.koplugin/source/copymanga/init.lua#L236) 现在只有 `return Toc.read(identity.source_id, identity.stable_id)`；唯一调用位于[同文件第 270 行](book.koplugin/source/copymanga/init.lua#L270)。它是局部函数，不是调用方依赖的公开门面，也不再增加 IO、兼容或分派语义。

   最小方案：在唯一调用点直接调用 `Toc.read`，删除局部包装；不另建辅助模块。

2. **[P3] `tidyPath` 重复执行已有路径规范化。** [`source/kavita/setting.lua:314`](book.koplugin/source/kavita/setting.lua#L314) 先 `gsub("/+", "/")`，再调用 [`utils/paths.lua:73`](book.koplugin/utils/paths.lua#L73) 的 `userPath`；后者自身已经压缩重复斜杠。调用点为[第 356 行](book.koplugin/source/kavita/setting.lua#L356)、[第 365 行](book.koplugin/source/kavita/setting.lua#L365)和[第 518 行](book.koplugin/source/kavita/setting.lua#L518)。没有语义分叉，只是重复变换加零语义包装。

   最小方案：三个调用点直接复用 `Paths.userPath`，删除 `tidyPath`，保持显示结果不变。

### 三、无效防御及吞错

3. **[P3] 对同一交付目录里的 `ProgressDB.list` 做“旧安装”兼容没有有效契约。** [`source/kavita/volume_list.lua:150`](book.koplugin/source/kavita/volume_list.lua#L150) 检查 `list` 是否存在，不存在就逐卷 `get`。本次同时交付查询接口与调用者，正常安装没有这两份代码分别升级的接口契约。旧测试桩缺字段应该暴露，而不是被生产分支掩盖，并退回 N+1 查询。

   最小方案：直接调用 `ProgressDB.list`，更新实际需要的测试桩；不删外部数据校验，不为内部模块造版本探测。

4. **[P3] 设置读取的 `or {}` 掩盖内部契约破坏。** [`features/remote/settings.lua:177`](book.koplugin/features/remote/settings.lua#L177) 对 `Settings.get`、`getSource` 再补空表，而 [`utils/settings.lua:82`](book.koplugin/utils/settings.lua#L82) 和[第 109 行](book.koplugin/utils/settings.lua#L109) 已保证返回配置表。模块损坏或坏测试桩返回 nil 时，这个分支把故障伪装成可以继续保存的空配置。

   最小方案：删掉两处 `or {}`，保留既有设置读取契约。这里不是来自网络的可空数据。

### 四、行为缺陷，按影响排序

5. **[P1，已复现] 换库清理失败后仍激活新配置，并报告保存成功。**

   [`source/logout.lua:67`](book.koplugin/source/logout.lua#L67) 的 `replaceLibrary` 约定调用方先保存新凭据；`Store.forgetSource` 返回 false 后仍执行 `Registry.reload`。[`replaceWebdav`](book.koplugin/source/logout.lua#L79) 有相同顺序。远程设置的[Moon 保存](book.koplugin/features/remote/settings.lua#L73)、[WebDAV 保存](book.koplugin/features/remote/settings.lua#L126)和[源表单保存](book.koplugin/features/remote/settings.lua#L159)忽略返回值，[`applyForm`](book.koplugin/features/remote/settings.lua#L245)最终当成功处理。

   本地目录也是同类失败语义：[`source/local/setting.lua:216`](book.koplugin/source/local/setting.lua#L216) 先保存新根目录，随后忽略 `Store.forgetOldRoot` 的 false，仍提示“已保存”、重载并扫描。

   **触发条件：** 清库事务/事件失败，且正在切换服务器、账号库、WebDAV 根或本地书籍根。

   **复现：** 注入 `forgetSource=false`，确认 `replaceLibrary` 返回 false 但已经 reload；注入 `replaceLibrary=false`，真实远程设置保存仍返回成功且新 URL 已落盘；注入 `forgetOldRoot=false`，新目录仍保留、reload 仍执行、提示仍为“已保存”。

   **风险边界：** 已复现的是失败继续激活和成功响应。跨库污染没有对真实远端执行，但路径明确：[`main.lua:78`](book.koplugin/main.lua#L78) 会把遗留脏行交给当前已配置的源；[Moon 同步](book.koplugin/source/moon/init.lua#L261)先推待删再拉书架。若新旧库 stable ID 重合，旧墓碑可能删除新库的书，旧进度/笔记也可能串库。

   最小方案：把换库顺序与调用方一起收紧——停旧任务、成功清理旧库后，再保存并激活新配置。若保持当前“先保存”契约，则失败必须回滚配置、恢复旧源且明确报错，不能只补一条 toast 后继续用新凭据。补清库失败、成功换库、纯本地书不被 WebDAV 清理的测试。

6. **[P2，已复现；关联既有路径] Kavita 心跳绕过本次新增的进度决议门禁。**

   本次 [`book/progress.lua`](book.koplugin/book/progress.lua#L31) 新增决议状态与 [`canPush`](book.koplugin/book/progress.lua#L56)，通用上传路径已使用它。但既有 [`source/kavita/init.lua:885`](book.koplugin/source/kavita/init.lua#L885) 心跳只检查 busy、联网、30 秒和位置变化，就直接调用 `putProgressAsync`。

   **触发条件：** 进度仍在 `choosing`，用户尚未选择本地或云端，但产生页变化并满足心跳间隔。

   **复现：** 设置 `Progress.canPush=false`、时间推进 31 秒、发送 `page_changed`；`putProgressAsync` 仍被调用一次，门禁仍为 false。请求使用 stub，没有访问真实 Kavita。

   **错误语义：** 用户还没作出冲突选择，本地位置已经可以发往云端；统一决议保护对该源不完整。

   最小方案：心跳发出前复用 `Progress.canPush`，保留最近位置供解锁后的下一拍补发，不新增另一套状态。补 pending/choosing 时不发送、解锁后发送的回归。

7. **[P2，已复现] 冷目录尚未恢复时选择云端，把全书进度应用到了当前章。**

   [`reader/session/chapter.lua:191`](book.koplugin/reader/session/chapter.lua#L191) 改为 `Toc.peek`，冷启动时允许 `chapter.toc=nil`；[`afterBootstrap`](book.koplugin/reader/session/chapter.lua#L233)才异步读取。与此同时，[会话 bootstrap](book.koplugin/reader/session.lua#L102)先拉云端进度，后调用[目录恢复](book.koplugin/reader/session.lua#L290)。

   [`applyChosenPos`](book.koplugin/reader/session/progress.lua#L346) 只有拿到 toc 才 `gotoChapter`；没有 toc 就走整本文档的 `applyPosition`。[`adoptCloud`](book.koplugin/reader/session/progress.lua#L551)已经保存云端章号，随后解除决议，因此数据库和当前文档可以不同步。

   **触发条件：** 按章阅读、目录内存缓存未命中、云端回包及用户选择早于异步目录恢复。大目录分批读取使该窗口确实存在。

   **复现：** 当前是第 3 章、toc=nil，选择云端第 9 章、全书 fraction=.85。数据库采用第 9 章，但 `gotoChapter` 调用零次，身份仍是第 3 章，只发生当前文档内 `GotoPage`。对照填入 10 章目录后，同一输入正确调用 `gotoChapter(9)`。

   最小方案：保留异步首绘，但章节进度决议必须等待现有目录任务准备完成，再保存并跳章；目录失败时保留未决状态并明确提示。按章身份不能退化成整本比例跳页。补冷目录、早到远端回包、选择云端的回归。

8. **[P2，已复现] JD 跳过坏 ID 后，把不完整书架当成完整快照，隐藏合法旧书。**

   [`source/jdread/client.lua:191`](book.koplugin/source/jdread/client.lua#L191) 对非法 `book_ids` 只记录日志并跳过；结果照常送入 [`Shelf.syncAsync`](book.koplugin/source/jdread/init.lua#L65)。[`source/shelf.lua:188`](book.koplugin/source/shelf.lua#L188)没有“不完整”标记，正常执行 reconcile；[`books_db.lua:453`](book.koplugin/book/books_db.lua#L453)将快照中缺席的已同步书标为 deleted。空快照保护覆盖不了“部分合法、部分损坏”。

   **触发条件：** 远端响应混有合法 ID 与坏行，坏行所对应的书已存在本地。

   **复现：** 真实 SQLite 预置已同步书 1、2、3，真实 Client/Shelf/Mapper 接收 `1、false、3`。同步返回成功，书 2 变成 `deleted=1, sync_status=1`，`result.hidden=1`。

   **影响边界：** 书从本地书架消失，不是物理文件删除；后续完整快照可以恢复。跳过解析错误不能被解释成远端明确移除。

   最小方案：遇到坏行时明确标记快照不完整，本轮只合入合法条目，不按缺席下架；不能提供这种语义时就返回错误并保留旧书架。补部分坏、全坏和完整快照确实移除书的对照。

9. **[P2，已复现] 本地目录设置行捕获全局 `repaint`，保存后回调抛错。**

   [`source/local/setting.lua:32`](book.koplugin/source/local/setting.lua#L32) 先定义 `localPathRow`，回调里使用 `repaint`；`local function repaint` 却在[第 41 行](book.koplugin/source/local/setting.lua#L41)才声明，不在此前闭包的词法作用域。

   **触发条件：** 从实际本地目录设置行打开选择器，保存后执行 `on_saved`。

   **复现：** 调用真实 `Setting.rows()[1].callback`，模拟保存完成，抛出 `attempt to call global 'repaint' (a nil value)`。LuaLS 同样报告第 38 行 `undefined-global`。已有测试直接打开 `Setting.open`，绕过了坏入口。

   **错误语义：** 保存可能已经完成，但刷新回调失败；由入口 guard 报错，并非正常保存闭环。

   最小方案：把 `repaint` 的局部定义移到 `localPathRow` 之前。补从真实设置行进入并保存的测试，不再只测被调用函数。

10. **[P2，已复现] 详情页“没有续读目标”的负缓存在接口边界丢失，重绘重复计算。**

    [`desktop/detail/actions.lua:91`](book.koplugin/desktop/detail/actions.lua#L91) 用 `false` 表示已算过且无目标，却返回 `self._reading_target or nil`；[`layout.lua:91`](book.koplugin/desktop/detail/layout.lua#L91)把 nil 交给 `actionPlan`，而 [`actions.lua:485`](book.koplugin/desktop/detail/actions.lua#L485)把 nil 解释为尚未计算，再调用源的 `readingTarget`。

    **触发条件：** 源支持 `readingTarget`，但当前书没有续读目标。

    **复现：** 首次计算调用一次；之后两次真实 `actionPlan` 调用又各算一次，总计三次，即使内部 `_reading_target` 已经是 false。已有测试覆盖非空目标，没有覆盖负缓存。

    **错误语义：** 本次“详情页一次打开只算一次”的优化对无目标路径失效；首次构建多算，后续更新仍重复，代价取决于源的查询实现。

    最小方案：给 `actionPlan` 保留 false 哨兵，nil 只表示未计算；真正开书时仍按源接口把“无目标”转为 nil。补 nil 返回值跨多次布局更新只查询一次的回归，不另造缓存对象。

## Linus 式方案

1. 先修换库失败语义。旧库清理、新配置落盘与源激活必须是同一成功路径；清理失败不能宣称成功。
2. 把进度决议门禁覆盖到 Kavita 心跳，并让章节云端选择等目录就绪。复用现有门禁与异步任务，不增加平行状态机。
3. 保证只有完整书架快照才能按缺席下架；补部分损坏响应回归。
4. 移动 `repaint` 定义、保留详情页 false 哨兵。P3 包装和内部防御随相关修改删除，不单独开架构重构。

## 代码检查

**语法：** ✅ 固定提交快照的 687 个离线 spec 均执行成功。LuaLS ⚠️ 未达到仓库零诊断要求；`repaint` 未定义已有静态与运行时双重证据。

**逻辑：** ❌ 六项行为缺陷均已复现；现有测试全绿不等于换库失败、冷目录和不完整快照的语义正确。

**兼容性：** ✅ 本次没有修改业务代码。修复时须保持源 ID/stable ID、既有配置键、模块路径、数据库格式、源回调及开书参数契约；不以同步加载整份目录来撤销首绘优化。

### 验证记录与边界

| 检查 | 结果 | 说明 |
|---|---|---|
| 固定提交快照 `./tests/run.sh` | **687 passed，0 skipped，0 failed；107680 assertions** | 独立解包 `5b0c24d`，使用独立测试沙箱；没有带入后续未提交改动 |
| 六组隔离复现 spec | **6 passed，0 skipped，0 failed；1189 assertions** | 同一固定快照重跑；部分复用既有 spec 作夹具，不能称为新增 1189 个独立测试 |
| `lua-language-server --check="$PWD" --configpath="$PWD/.luarc.json" --checklevel=Warning` | **55 problems，27 files，退出 1** | 对工作树执行的全仓检查；混有范围外已有问题，未做基线对照，不能把 55 条全部归成本时段新增 |
| 设备与真实服务 | 未执行 | 本任务只审计；复现用离线桩/真实沙箱 SQLite，不部署设备、不操作真实远端 |

LuaLS 中与本次变更明确相关的证据包括 `source/local/setting.lua:38` 的未定义 `repaint`，以及本地 WebDAV、微信章节新增第三个回调参数与旧注解不匹配；测试桩也有新增字段/类型诊断。未量化全部新增诊断，不把范围外警告混入行为发现数量。

复现文件及日志保留在本次会话目录：

```text
/Users/ankio/.copilot/session-state/848c33cc-f6f8-4ebb-bd76-4443b9eaaa7c/files/
```

六个文件为 `audit_local_setting_spec.lua`、`audit_detail_spec.lua`、`audit_logout_spec.lua`、`audit_cold_progress_spec.lua`、`audit_jdread_spec.lua`、`audit_kavita_progress_spec.lua`。最终证据为 `audit-baseline-tests.log`、`audit-baseline-repros.log`，静态诊断为 `audit-luals.log`。早期复现脚本中的断言 API/夹具问题已修正，以上结果来自修正后的完整重跑。

## 过度设计

**🟡 可接受。** 没必要重写架构；真正多余的是内部接口兼容分支和残留包装。主要缺陷是边界语义没收紧，不是抽象层不够多。

## 冗余

* **无意义函数：** 局部 `anyToc`；重复规范化的 `tidyPath`。
* **无意义类：** 未发现本范围内需要删除的类。
* **无意义抽象：** 未发现需要新建或合并框架的证据；公开门面不计入。
* **无意义判空：** 远程配置读取的两处 `or {}`；`ProgressDB.list` 存在性兼容分支。
* **无意义转换：** `tidyPath` 重复压缩斜杠。
* **无意义异常处理：** 未列入额外高置信条目；换库吞掉失败返回值已计入 P1，不能靠新增 `pcall` 掩盖。
* **可删除代码：** 上述局部包装和内部 fallback；源协议差异、公开 API、外部输入校验不删。

## 致命问题

**清库失败，新凭据仍生效，界面仍说成功。** 这让新旧库共享同一源 ID 下的遗留记录，并把后续同步变成跨库污染风险。只改提示、不阻止新库激活，不算修复。

## 最终结论

**需要修改，不需要重写。**

优先级：换库失败闭环 → 进度决议与冷目录 → 不完整书架对账 → 设置回调及负缓存。先用能失败的测试钉住这些语义，再顺手删 P3 冗余；不要为了十来行包装引入新的 Service、Manager 或状态层。
