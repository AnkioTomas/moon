# `book.koplugin/` 代码审计报告

审计基线：`52c495ff`（2026-10-26），日期 2026-10-26。范围为 `book.koplugin/`（排除 `types/`、`demo/`）约 **612** 个 Lua 源文件、约 **169805** 行；重点检查了锁屏/壁纸绘制、书库 SQL、Rare/X-Ray/reflow 热路径、HTTP DNS、源段评编排、吞错 `pcall`。以下是有证据的发现，不声称逐行形式化验证。初版仅生成报告。后续已按 P1→P2 落地优化（见文末「已落地修复」）。

**本次重点**：Kindle 低端机（慢 CPU、小内存、慢闪存、墨水屏刷新贵）上的**卡顿 / 数秒冻结 / OOM 风险**；重复实现与吞错按技能顺序附带。

## 需求理解

找出会让低端 Kindle 在休眠、开书、翻页、图书馆、锁屏上卡顿或内存爆的主线程重活，以及重复实现、空转发、无效防御里会掩盖故障或拖累排障的项；给出最小、兼容的修正顺序。

## 核心判断

**值得做。** 最严重的真实问题不是「架构不够优雅」，而是：**休眠锁屏与壁纸在主线程同步解码/合成整屏图**，以及 **全书正文一次性 `table.concat` 进内存**——这和 Kindle 的电源键路径、小内存、慢闪存直接冲突。

## 关键问题

* **数据结构：** 锁屏组合图既是磁盘缓存（`compose.png`）又在 miss 时同步重建；壁纸在 `paintTo` 里按 key 懒解码进进程缓存；书库列表每次查询都先 `COUNT(*)` 再分页。
* **复杂度：** 最大卡顿来自「绘制/休眠入口上的同步 IO + 图像解码 +（insight 时）多段聚合 SQL」，不是任务队列本身。
* **最大风险：** 电源键休眠瞬间 UI 冻结数秒；开壁纸弹窗时首帧卡死；X-Ray/重排全书时峰值内存把低内存 Kindle 打进 OOM。

## 详细发现

### 一、重复实现，优先处理

1. **[P2] 起点 / 晋江 `withChapterId` 控制流逐字同构。** [`source/qidian/init.lua`](book.koplugin/source/qidian/init.lua#L343) 与 [`source/jjwxc/init.lua`](book.koplugin/source/jjwxc/init.lua#L287) 都是 `loadTocAsync` → 按下标取章 → `start(uid, cb)` → cancel 链；仅错误文案不同。修一处漏一处会让段评定位行为分叉。
   最小方案：抽 `source` 下薄函数（传入错误串），两源各一行调用。不要加 Service。

2. **[P2] 四源段评 API 编排模板重复（热点 / 翻页 / 定位）。** [`qidian`](book.koplugin/source/qidian/init.lua#L333)、[`jjwxc`](book.koplugin/source/jjwxc/init.lua#L277)、[`fanqie`](book.koplugin/source/fanqie/init.lua#L433)、[`wechat`](book.koplugin/source/wechat/init.lua#L851) 共用 `ReviewCache` + 章 uid 解析骨架，但 uid 解析语义已分叉（微信 `resolveChapterUidAsync`、番茄目录下标、起点/晋江 `withChapterId`）。
   最小方案：只抽「ReviewCache + done」薄 helper，保留各源 uid 解析；禁止硬合并成一支。

3. **[P3] 晋江 / 起点 `Reviews.locate` 一行相同。** [`jjwxc/reviews.lua`](book.koplugin/source/jjwxc/reviews.lua#L138) 与 [`qidian/reviews.lua`](book.koplugin/source/qidian/reviews.lua#L103) 都是 `ReviewLocate.locate(paragraphs(html), …)`。
   最小方案：在 `book/review_locate.lua` 加 `locateFromHtml`，两源一行 re-export。番茄因 `blk/p_idx` 不同不可合并。

4. **[P3] 番茄 JSON decode 局部函数双份。** [`fanqie/client.lua`](book.koplugin/source/fanqie/client.lua#L68) 与 [`fanqie/reading.lua`](book.koplugin/source/fanqie/reading.lua#L22)。
   最小方案：一个 `decode(text, empty_err)`；或 reading 直接用 client 侧函数。

5. **[P3] 微信 / 京东目录缓存命中的异步调度未走 `SourceBase.defer`。** [`wechat/init.lua`](book.koplugin/source/wechat/init.lua#L262)（`nextTick` + guard）、[`jdread/init.lua`](book.koplugin/source/jdread/init.lua#L229)（裸 `nextTick`）。
   最小方案：缓存命中统一 `SourceBase.defer`，微信把 guard 包在回调里。

### 二、单行包装与空层

6. **[P3] 番茄 `Client:officialGetContentAsync` 纯转发。** [`fanqie/client.lua`](book.koplugin/source/fanqie/client.lua#L504) → `reading.fetchAsync`；唯一调用 [`fanqie/init.lua`](book.koplugin/source/fanqie/init.lua#L300)。
   最小方案：调用处直接 `reading.fetchAsync`，删 client 方法。

7. **[P3] 微信 `paragraphReviewsEnabled` 与 `review_setting.enabled` 重复。** [`wechat/init.lua`](book.koplugin/source/wechat/init.lua#L853) vs [`source/review_setting.lua`](book.koplugin/source/review_setting.lua#L13)。
   最小方案：微信改为 `return review_setting.enabled(self.id)`。

8. **[说明 · 保留]** `Source:locateHotspots` / `SourceBase:sync*Async` / 微信 `*Annotations` 是源多态或基类默认实现，调用点在 `features/reviews`、`book/note`、`reader/session`；删了会逼下层写源名，违反 feature 边界。

### 三、无效防御及吞错

9. **[P2] `http/mirror.lua` 对 settings 的 `pcall` 把失败变成空表，且 `save` 结果丢弃。** [`http/mirror.lua`](book.koplugin/http/mirror.lua#L74)–L98：`conf()` 失败返回 `{}`；`markDead`/`markOk` 的 `pcall(save)` 不看结果。契约：生产路径 `utils.settings` 必须可用。掩盖：镜像黑名单/优选「以为落盘了」实际没落。
   最小方案：直接 `get`/`save`；失败 `logger.warn`。测试用 stub，不要在 HTTP 层假装没配置。

10. **[P2] `main.lua` 吞掉 `Wake.boot` 失败。** [`main.lua`](book.koplugin/main.lua#L40)：`pcall(Wake.boot)` 无检查、无日志（对比上行 `logger.boot` 至少 warn）。掩盖：`.running` 标记失败、异常退出诊断失效。
    最小方案：与 boot banner 同级记 warn，或去掉 pcall。

11. **[P2] `Toc.setWords` 对不抛错的 API 再套 `pcall` 且忽略 `put` 失败。** [`source/toc.lua`](book.koplugin/source/toc.lua#L133)–L138。契约：`Toc.read`/`put` 返回值表达失败，不抛。掩盖：字数回填静默丢，页码估算长期错。
    最小方案：直接调用；`put` 失败 `logger.warn`。

12. **[P2] 起点 VIP 字体 JSON 坏了仍当成功。** [`source/qidian/fock.lua`](book.koplugin/source/qidian/fock.lua#L29)：decode 失败 → `{ data = {} }`。上游已保证 `randomFont` 是 string。掩盖：乱码章节看起来「解密成功」。
    最小方案：失败向上报字体解密失败；去掉空表兜底。

13. **[P3] Rare 注音度量失败静默常量。** [`features/rare/overlay.lua`](book.koplugin/features/rare/overlay.lua#L168) 附近：`pcall` 失败硬编码 `{ em = 1.3, bottom_em = 0.3 }` 无日志。掩盖：对齐怪却不知道字体挂了。
    最小方案：warn + 禁用 overlay 或显式失败。

### 四、性能 / 卡顿（Kindle 低端），按影响排序

14. **[P1，代码路径明确] 休眠锁屏 miss 时主线程同步整屏合成。** [`features/lockscreen/init.lua`](book.koplugin/features/lockscreen/init.lua#L87)–L98 在 `Screensaver.setup`（`event == nil`）里同步调 `M.refresh`；本地背景时 [`compose.lua`](book.koplugin/features/lockscreen/compose.lua#L139)–L156 `Background.ensure` 同步回调后立刻 `Render.write`（解码 + 画块 + 写 PNG，见 [`render.lua`](book.koplugin/features/lockscreen/render.lua#L147)）。模块头注释写明「变了就当场重画」。触发：改锁屏设置/主体/背景后按电源键。Kindle：休眠路径上用户已在等，整屏 RGB 画布 + 闪存写盘常见数秒卡死。
    最小方案：休眠只接受缓存命中；miss 用旧图/纯色先过，合成挪到唤醒后或 `workers.job`（编码可子进程）；不要在 `setup` 同步等在线资源。

15. **[P1，代码路径明确] 壁纸在 `paintTo` 路径上主线程全屏解码。** [`features/wallpaper/init.lua`](book.koplugin/features/wallpaper/init.lua#L265)–L321：`surface` 在 key miss 时 `renderImageFile` + `ImageWidget:paintTo`；`paintTo`/`modal.backdrop` 每帧可走进这条路径直到缓存命中。开书阅读壁纸 [`onReaderReady`](book.koplugin/features/wallpaper/init.lua#L454)–L468 再同步解码并 `writePNG`。Kindle：弹窗首开/换图/分辨率变化时 UI 冻结；与 CREngine 开书叠加更痛。
    最小方案：对齐 [`ui/themes/widgets/image/core.lua`](book.koplugin/ui/themes/widgets/image/core.lua) 的预算队列；`paintTo` 只 blit 已就绪 bb；预解码用 `nextTick`；阅读壁纸推迟到首帧后。

16. **[P1，代码路径明确] 锁屏 insight 主体合成时同步跑完整 `readingInsight`。** [`features/lockscreen/insight.lua`](book.koplugin/features/lockscreen/insight.lua#L91) → [`book/catalog.lua`](book.koplugin/book/catalog.lua#L696)–L709（`summaryBySource` / `daily*` / `hourly*` / `sessionRows(400天)` / `progressBooks`）再 `PAGE_MODULES[id]:build`。与 **#14** 叠在休眠路径上。Kindle：多段聚合 SQL + 半套 Insight 组件树 `getSize`。
    最小方案：锁屏只用轻量 KPI 快照，或 insight 主体禁止 miss 时同步合成、只复用已生成 `compose.png`。

17. **[P1，代码路径明确] 全书正文一次性进内存。** [`features/reflow/extract.lua`](book.koplugin/features/reflow/extract.lua#L106)–L151：`pages[]` + `table.concat(pages, "\n")`；[`features/xray/ui.lua`](book.koplugin/features/xray/ui.lua#L173) / [`features/reflow/init.lua`](book.koplugin/features/reflow/init.lua#L144) 走同一入口。批间 `later` 只防卡死，不降峰值内存。Kindle：百万字级字符串 + Lua 表易 OOM。
    最小方案：按页追加临时文件；X-Ray `Fetch.chunks` 读窗口，禁止先 concat 全书再切。

18. **[P2，代码路径明确] Rare 翻页：主线程读生字本全表 + 加载词库全文，再进子进程扫。** [`features/rare/overlay.lua`](book.koplugin/features/rare/overlay.lua#L345)–L353 在 `job.run` **之前**调 `catalog.active()` / `vocab.set()`；[`vocab.lua`](book.koplugin/features/rare/vocab.lua#L46) `SELECT word FROM vocabulary` 无 LIMIT；[`catalog.lua`](book.koplugin/features/rare/catalog.lua#L81) `read("*a")` + `Lexicon.parse`（有 mtime 缓存，冷启动/换库仍痛）。`paint` 每帧 [`get("features.rare")`](book.koplugin/features/rare/overlay.lua#L390)。
    最小方案：把 vocab/catalog 加载挪进子进程或预热；`paint` 缓存 `rare_enabled`。

19. **[P2，代码路径明确] 书库每次 `listBooks` 先全表 `COUNT(*)`。** [`book/catalog.lua`](book.koplugin/book/catalog.lua#L394)–L426；`limit=1` 的随机书同样先 COUNT。图书馆筛选项 [`filters`](book.koplugin/book/catalog.lua#L600) 一次最多 6 路 `GROUP BY`。Kindle：万级书时翻页/筛选顿一下。
    最小方案：翻页才 COUNT；随机用 `ORDER BY RANDOM() LIMIT 1`（待确认 SQL）；筛选项按当前页签 lazy。

20. **[P2，代码路径明确] 书架 reconcile 大快照时主线程长事务逐本 upsert。** [`book/books_db.lua`](book.koplugin/book/books_db.lua#L377)–L404。Kindle：数千本同步时 UI 与 sqlite 抢锁。
    最小方案：批量 UPSERT / 单事务 apply diff；重计算放子进程后主进程只写 diff（待确认事件顺序）。

21. **[P2，代码路径明确] 桌面每次 `paintTo` 等墨水刷新结束。** [`desktop/init.lua`](book.koplugin/desktop/init.lua#L432)–L440：`Screen:refreshWaitForLast()`。注释说明为防半帧错乱。Kindle：E-Ink 控制器慢时拉长整帧。
    最小方案：仅全刷前 wait；`ui` 局刷跳过（需真机确认半帧是否再现）。

22. **[P2，代码路径明确] subscribe 公网检查同步 `dns.getaddrinfo`。** [`features/subscribe/init.lua`](book.koplugin/features/subscribe/init.lua#L94)。HTTP 侧已有 [`http/turbo/patch.lua`](book.koplugin/http/turbo/patch.lua#L14)–L47 缓存，但订阅探测仍直打 DNS。弱网/无网时阻塞到超时。
    最小方案：复用 turbo DNS 缓存，或挪到 `workers.job`；失败短 TTL 记负缓存。

23. **[P2，待确认边界] 设置页 `refresh_seconds` 默认 2s 轮询重建视图。** [`desktop/pages/setting/overlay.lua`](book.koplugin/desktop/pages/setting/overlay.lua#L122)–L129。哪些 spec 开启待确认；开启时墨水屏频繁 `setDirty`。
    最小方案：数值变才 patch；轮询 ≥5s。

24. **[P3 / 已缓解]** 业务侧未直接调用 `isOnline`（[`http/request/fetch.lua`](book.koplugin/http/request/fetch.lua#L58) 明确禁用）；封面异步队列有 `BUDGET_MS`；Rare/X-Ray 页扫进 `workers.job`；蓝牙 30s、顶栏按分钟——这些方向正确。大量设置页仍用 `NetworkMgr:runWhenOnline`（是否内部同步 DNS：**待确认**，`translate` 注释已警告 `willRerunWhenOnline`）。

### 五、其它正确性（非性能）

25. **[P2，代码路径明确] `reader/session/document_toc.lua` 填充 TOC 的 `pcall` 不读返回值。** 失败被当成「无目录」。最小方案：warn + 明确 fallback。

## Linus 式方案

1. **先砍休眠/绘制路径上的同步重活（#14–#16）**：缓存命中才进 `Screensaver.setup`；壁纸解码出 `paintTo`；insight 锁屏禁止现场重算。这是用户每天按电源键会踩到的。
2. **再砍峰值内存（#17）**：extract 流式落盘，X-Ray/reflow 读窗口。
3. **图书馆 / Rare 主线程 IO（#18–#20）**：COUNT 与全表 vocab 移出热路径；reconcile 批量写。
4. **钉住分叉语义后再去重（#1–#2）**；删确认无调用转发（#6）；吞错先修 mirror/Wake/Toc/fock（#9–#12）。不要为去重发明 Service。

## 代码检查

**语法：** ✅ `./tests/run.sh` 全绿。

**逻辑：** ⚠️ 休眠锁屏 miss、壁纸 paintTo 解码、全书 concat 三条错误/慢路径未闭环到「不卡 UI」；mirror save 失败路径未暴露。

**兼容性：** ✅ 本次未改代码。修复时必须保持：Screensaver 封面路径契约、壁纸 scope API、`Catalog.listBooks` 返回 `(rows, total)`、X-Ray `xray_scan` 指纹语义、源 `paragraphReviews*` 多态、HTTP 镜像配置键。

验证记录：`./tests/run.sh` → **479 passed, 1 skipped, 0 failed (70767 assertions)**。真机未跑；P1 为代码路径审计，未在 Kindle 上计时复现。

## 过度设计

**🟡 可接受**

任务队列、job 边界、`isConnected`、封面预算队列方向正确。局部噪音：锁屏「缓存 + 同步重建」双轨、壁纸解码塞进绘制路径、源侧段评编排复制。不是该推倒重写的程度。

## 冗余

* **无意义函数：** `fanqie.Client:officialGetContentAsync`（#6）
* **无意义类：** 未发现
* **无意义抽象：** 未发现新增 Manager/Factory；段评重复是复制而非错误抽象
* **无意义判空：** 少量（Toc.setWords 对不抛 API 的 pcall）
* **无意义转换：** `fock.lua` 对已是 string 的 `tostring(info.randomFont)`
* **无意义异常处理：** mirror/Wake/Toc/fock/rare 度量（#9–#13）
* **可删除代码：** 微信 `paragraphReviewsEnabled` 体可改为一行 `review_setting`；qidian/jjwxc `withChapterId` 可并一处

## 致命问题

**按电源键锁屏时，若组合图缓存失效，主线程同步解码背景、跑 insight SQL、画整屏、写 PNG——低端 Kindle 上这就是数秒「假死」。** 壁纸 `paintTo` 首帧解码是第二号杀手。全书 concat 是第三号（内存）。

## 最终结论

**需要修改**

修正顺序：

1. P1 性能：锁屏休眠路径只走缓存（#14）→ 壁纸解码出绘制路径（#15）→ insight 锁屏轻量化（#16）→ extract 流式（#17）
2. P2 性能：Rare 主线程预载（#18）、COUNT/筛选（#19）、reconcile（#20）、subscribe DNS（#22）
3. P2 正确性：mirror save / Wake.boot / Toc.setWords / fock 字体失败（#9–#12）
4. P2/P3 去重与空转发：withChapterId、段评 helper、officialGetContentAsync（#1–#6）

单行包装只删无调用且非兼容入口的。性能修复以「主线程不做重 IO/解码」为铁律，不要为「更通用」再加一层调度框架。

## 已落地修复（同会话）

| 项 | 改动 |
|---|---|
| #14 锁屏休眠 | `prepareSuspend`：只接管路径 / 过期图；重建改 `desktop.activated` |
| #15 壁纸 | `paintTo` 只 blit 缓存；miss 时 `nextTick` 解码后 `setDirty`；阅读壁纸推迟首帧后 |
| #16 insight | 同 `cache_key` 复用 `readingInsight` 结果 |
| #17 extract | 边取边写临时文件，去掉 `pages[]`+concat 双峰 |
| #18 Rare | 词库 parse 进 fork 子进程；`paint` 缓存开关 |
| #19 抽书 | `listBooks{random=true}` 走 `ORDER BY RANDOM()`，首页不再 COUNT+OFFSET |
| #22 DNS | subscribe 失败负缓存 10s |
| #9–#12 | mirror save 记 warn；Wake.boot 记 warn；Toc.setWords 去吞错；fock 坏 JSON 抛错 |

未做：书架 reconcile 批量（#20）、筛选 6 路 GROUP BY lazy、段评去重。真机 Kindle 计时仍待确认。
