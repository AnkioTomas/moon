--[[--
数据源运行时基类。

各适配器继承本类，只覆盖自己支持的传输方法。
四类同步中不支持的方向异步 skipped；所有查询默认读取本地 catalog。
书架：远端快照 reconcile（pulled）+ 本地脏成员经 add/delete 上行（pushed）。
本地删除只标 deleted；同步时推云端真删。
全量同步：本地优先 push，再 pull。进度 pull 仅开书（冲突让用户选）；笔记有网即推、开书再拉。
本源脏行由 pushDirty 作为后台任务推送（main 在启动、唤醒、联网时触发）：书架、笔记、统计，进度最后。

IO 一律 XxxAsync(..., cb) 返回 { cancel }，取消后不回调；当场能回的结果也用 SourceBase.defer(cb, ...) 下一帧回调，
不支持的域用 SourceBase.skipped(cb, reason)。无 IO 的 capabilities / configured / coverRequest 保持同步。
capabilities() 是 UI 开关（scrape / edit / stats_pull，默认 false，用 SourceCapabilities.supports* 判断），
不是「有没有这个函数」；全本缓存看有没有 cacheAllChaptersAsync，进度双向看 get/putProgressAsync 是否都在。
源外代码只碰 source.<id>（经 registry）和 source.<id>.setting；require("source.<id>")，禁止写 .init。
新增内置源：source/<id>/init.lua（meta + new）、可选 setting.lua、registry 的 BUILTIN 加一项，测试放 tests/source/<id>/。
标准拉快照 + add/remove 书架用 source.shelf；推墓碑一律 Shelf.pushDeletes。模块顶层不 require KOReader UI。

@module koplugin.book.source.base
--]]

---@alias SourceId "moon"|"wechat"|"jdread"|"copymanga"|"fanqie"|"qimao"|"legado"|"jjwxc"|"qidian"|"qqreader"|"iread"|"changpei"|"xiaoxiang"|"local"|string

---@alias BookSourceType
---| '"book"' # 整本文件
---| '"chapter"' # 连续章节阅读

---@class BookSourceMeta
---@field id SourceId
---@field name string
---@field type BookSourceType 阅读形态

--- 能力是用户可用功能，不是「模块里有没有函数」。
--- 仅保留 UI 实际读取的开关；Source 基础契约和阅读形态不放在能力表中。
---@class StoreChipGroup
---@field chips { id: string, title: string }[]
---@field active string|nil

---@class SourceCapabilities
---@field scrape boolean 支持把外部元数据写入本地书籍记录（仅 local 为 true）
---@field edit boolean 支持编辑展示元信息（仅 local 为 true）
---@field stats_pull boolean 是否从远端拉取阅读统计并写入本地 reading_stats（各源自决映射与替换策略）

---@class SyncResult
---@field pulled integer
---@field pushed integer
---@field hidden integer
---@field conflicts integer
---@field skipped boolean
---@field reason string|nil
---@field push_error any|nil 本域整体未失败但有本地脏数据上报失败（脏标记保留待重试）

--- 单条阅读会话统计（落盘 reading_stats 后上报）。
---@class BookStatsRow
---@field id number|nil 本地 reading_stats 行 id（push 时由调用方带入，供 synced_ids 回报）
---@field source_id string 源标识
---@field stable_id string 源内书籍身份
---@field record_type string 记录类型：page/page_rollup/day/book/total
---@field page number 结束页
---@field start_time number 会话开始时间戳（秒）
---@field duration number 阅读时长（秒）
---@field total_pages number 全书页数
---@field chapter_idx number|nil 章节序号（按章阅读）
---@field chapter_fraction number|nil 章内进度 0..1
---@field event_count number|nil 汇总行包含的原始页事件数
---@field last_time number|nil 汇总行中最后一条原始事件时间

--- pullStatsAsync 可选替换范围：入库前删除本地已同步行，避免云端聚合与本地页记录双计。
---@class BookStatsPullReplaceRange
---@field stable_prefix string
---@field from_ts number
---@field to_ts number

---@class BookStatsPullReplace
---@field mode '"all_synced"'|'"ranges"'|'"synced_books"'|nil all_synced=全量快照，删除该源全部已同步行；缺省=按本批时间窗口清理已同步合成行
---@field stable_ids string[]|nil mode=synced_books 时只删这些书的已同步 page / page_rollup 行（本批为空也删）
---@field ranges BookStatsPullReplaceRange[]|nil mode=ranges 时按各前缀的独立时间窗口清理
---@field books string[]|nil 按 stable_id 精确整本替换 book_day / book_total（与 mode 无关）

--- pullStatsAsync 回包：纯数组为追加去重；带 replace 为云端优先覆盖入库。
---@class BookStatsPullResult
---@field rows BookStatsRow[]
---@field replace BookStatsPullReplace|nil
---@field commit fun()|nil 入库成功后调用（源借此记下已入库的远端版本）

--- pushStatsAsync 回包：结果为真即视为上传成功。
--- 逐条上报的源部分失败时，用 synced_ids 只确认已被远端接受的行，
--- 其余保持 sync_status=0 等下次重试，避免同一段时间被重复计时。
---@class BookStatsPushResult
---@field synced_ids number[]|nil 已被远端接受的 reading_stats 行 id；缺省表示本次全部行

--- 封面 HTTP 请求描述（UI 线程同步取，再异步下载）。
---@class BookCoverRequest
---@field url string 封面 URL 或本地 file:// 路径
---@field headers table 附加请求头（可空表）

--- 按章正文载荷：Source 只交内容，宿主写 HTML。
---@class ChapterContentPayload
---@field temporary boolean|nil 临时提示正文，不作为章节缓存
---@field title string|nil 章节标题
---@field book_title string|nil 书名（写入 HTML <title>，供阅读器/第三方插件认书）
---@field html string|nil HTML/XHTML 正文片段（优先）
---@field text string|nil 纯文本（无 html 时由宿主转段落）
---@field file string|nil 源已落盘的章节文件（如漫画 CBZ）：宿主原样登记，不写 HTML，优先于其余字段
---@field document string|nil 完整 HTML/XHTML 文档：宿主原样落盘，不套外壳、不改内容（优先于 html/text）

--- 统一数据源实例接口。
--- IO 方法一律异步：XxxAsync(...) 经 cb(data, err) 回传，返回值是可取消 job 或 nil；
--- 同步只保留无 IO 的元信息与本地描述方法（capabilities / configured / coverRequest 等）。
---
--- 本地唯一入口：书架、筛选、书架搜索、进度、笔记和统计查询只读 SQLite（book.catalog 等，不经源）。
--- 四个 sync*Async 按源与各自云端双向收敛；打开书和正文下载仍走源协议。
--- 不支持的域异步 skipped（不失败）。探测：progress=get+put；notes=push+pull；
--- stats=pushStatsAsync +（pull 另需 capabilities.stats_pull）。
---
--- 书架：远端快照 reconcile + 本地独有成员经 addToShelf 上行（wechat/jdread）；
--- 删除经 deleteBookAsync。local 扫盘；moon 无 add API（list/delete）。
---@class BookSource
---@field probing boolean|nil 正在探测协议
---@field dropChapterCache fun(self: BookSource, identity: BookIdentity, chapter: BookChapter)|nil
---@field id SourceId|nil 源标识
---@field name string|nil 展示名
---@field type BookSourceType 阅读形态
---@field pushDirty fun(self: BookSource) 推本源脏行（入后台任务队列）
---@field onEvent fun(self: BookSource, event: string, payload: table|nil) 业务事件（见 SourceBase:onEvent）
---@field ephemeral boolean|nil 只读不记：阅读会话不存进度、不记统计（订阅）
---@field capabilities fun(self: BookSource): SourceCapabilities 能力表
---@field configured fun(self: BookSource): boolean 是否已配置到可请求
---@field close fun(self: BookSource)|nil 释放资源
---@field syncBooksAsync fun(self: BookSource, opts: { force?: boolean, dirty_only?: boolean, on_progress?: fun(text: string, done: integer|nil, total: integer|nil) }|nil, cb: fun(result: SyncResult|nil, err: any)): table|nil 双向收敛书架；dirty_only 只推本地删/加；on_progress 在真实步骤（拉取/上传/写库…）处上报，done/total 为该步计数
---@field syncProgressAsync fun(self: BookSource, opts: { identity?: BookIdentity, dirty_only?: boolean }|nil, cb: fun(result: SyncResult|nil, err: any)): table|nil 双向收敛进度
---@field syncNotesAsync fun(self: BookSource, opts: { identity?: BookIdentity, dirty_only?: boolean }|nil, cb: fun(result: SyncResult|nil, err: any)): table|nil 双向收敛笔记
---@field cleanAnnotations fun(self: BookSource, items: table[], total_pages: integer|nil): table[]|nil 清洗并透传源私有注解字段
---@field prepareLocalAnnotations fun(self: BookSource, previous: table[], current: table[], deleted?: table): table[]|nil 根据源协议生成更新/删除状态（deleted 为本次被删条目）
---@field mergeAnnotations fun(self: BookSource, remote: table[], current: table[], paging: boolean|nil, authoritative: boolean): table[]|nil, integer|nil, integer|nil 按源身份语义合并注解（第二值 dropped = 远端已删条数；第三值 deduped = 远端同键重复被抑制的条数，都可为 nil）
---@field syncStatsAsync fun(self: BookSource, opts: { dirty_only?: boolean }|nil, cb: fun(result: SyncResult|nil, err: any)): table|nil 双向收敛统计
---@field deleteBookAsync fun(self: BookSource, identity: BookIdentity, cb: fun(ok: boolean, err: string|nil)): table|nil 本地优先删除（清缓存 + 墓碑），远端真删归 syncBooksAsync
---@field searchAsync fun(self: BookSource, keyword: string, cb: fun(res: { data: Book[] }|nil, err: string|nil)): table|nil 书城搜索（可选；有这个方法就是可搜索源，书城页按此列出）
---@field browseAsync fun(self: BookSource, opts: { node?: string, limit?: integer }, cb: fun(res: { data: Book[], groups: StoreChipGroup[] }|nil, err: string|nil)): table|nil 书城浏览（可选；无搜索词时书城页按 groups 画 chip 行、按 data 画书。node 是 chip 的 id，缺省由源选默认；源每次返回完整 groups 并标出 active，书城页不认识榜单 / 分类）
---@field getDetailAsync fun(self: BookSource, identity: BookIdentity, cb: fun(data: Book|nil, err: string|nil)): table|nil 书籍详情
---@field openBookAsync fun(self: BookSource, identity: BookIdentity, opts: table|nil, cb: fun(path: string|nil, err: string|nil, meta: { handled?: boolean }|nil)): table|nil 根据书籍身份解析、落盘并登记物理文档；按章源通过 opts.chapter_idx 指定章节；取消后不回调；源已自行展示（如在线漫画查看器）时回调 `nil, nil, { handled = true }`，桌面不开阅读器也不提示
---@field loadTocAsync fun(self: BookSource, identity: BookIdentity, cb: fun(toc: BookChapter[]|nil, err: string|nil), force?: boolean): table|nil 拉取并持久化章节目录
---@field prefetchChaptersAsync fun(self: BookSource, identity: BookIdentity, toc: BookChapter[], from_idx: integer, count: integer, cb: fun(cached: integer, total: integer, failed: integer, err: any)|nil): table|nil 阅读期预取后续章节
---@field getProgressAsync fun(self: BookSource, identity: BookIdentity, cb: fun(data: ProgressPosition|nil, err: string|nil, meta: table|nil)): table|nil 拉取远端进度；meta.empty 表示远端无记录
---@field putProgressAsync fun(self: BookSource, identity: BookIdentity, pos: ProgressPosition, cb: fun(ok: boolean|nil, err: string|nil, meta: table|nil)): table|nil 推送进度
---@field coverRequest fun(self: BookSource, identity: BookIdentity): (BookCoverRequest|nil, string|nil) 封面请求描述（纯构造，无 IO）
---@field importBookAsync fun(self: BookSource, local_path: string, filename: string, cb: fun(ok: boolean|nil, err: string|nil)): table|nil Z-Library 导入目标（local 移入）
---@field pushStatsAsync fun(self: BookSource, rows: BookStatsRow[], cb: fun(data: BookStatsPushResult|nil, err: string|nil)): table|nil 上报领域统计记录；协议细节由源处理
---@field pullStatsAsync fun(self: BookSource, cb: fun(result: BookStatsRow[]|BookStatsPullResult|nil, err: string|nil)): table|nil 拉取领域统计记录（可选 replace 覆盖策略）
---@field statsIdentities fun(self: BookSource, identity: BookIdentity): string[]|nil 详情页阅读统计要并入的书身份（如多卷书把卷行并进 series 行）；缺省只看书自己
---@field pushNotesAsync fun(self: BookSource, identity: BookIdentity, annotations: table[], cb: fun(data: table|nil, err: string|nil, meta: table|nil)): table|nil 上传划线/书签
---@field pullNotesAsync fun(self: BookSource, identity: BookIdentity, cb: fun(data: table[]|nil, err: string|nil, meta: table|nil)): table|nil 拉取划线/书签
---@field localizeAnnotations fun(self: BookSource, document: table|nil, annotations: table[], html_path: string|nil, current: table[]|nil): table[]|nil 按章 HTML 把远端划线定位到本地 xpointer
---@field cacheAllChaptersAsync fun(self: BookSource, identity: BookIdentity, on_progress: function|nil, cb: function, range: ChapterCacheRange|nil): table|nil 章节模式缓存：range 缺省全本，否则从当前阅读章起一段
---@field isTocCurrent fun(self: BookSource, toc: BookChapter[]|nil): boolean|nil 本地目录缓存是否仍有效
---@field refreshTocAsync fun(self: BookSource, identity: BookIdentity, cb: fun(toc: BookChapter[]|nil, err: string|nil)): table|nil 强制刷新目录

local logger = require("utils.log")
local _ = require("gettext")

local SourceCapabilities = {}

--- 源是否将远端阅读统计同步入库（UI 与 book.stats 统一入口）。
---@param source BookSource|nil
---@return boolean
function SourceCapabilities.supportsStatsPull(source)
    return source ~= nil and source:capabilities().stats_pull == true
end

--- 源是否允许刮削（UI 与 desktop.detail.scrape 统一入口）。
---@param source BookSource|nil
---@return boolean
function SourceCapabilities.supportsScrape(source)
    return source ~= nil and source:capabilities().scrape == true
end

--- 源是否允许编辑展示元信息（UI 统一入口）。
---@param source BookSource|nil
---@return boolean
function SourceCapabilities.supportsEdit(source)
    return source ~= nil and source:capabilities().edit == true
end

---@class SourceBase : BookSource
local SourceBase = {}
SourceBase.__index = SourceBase

--- 下一帧调 cb(...)，返回可取消句柄。IO 方法一律异步回调：命中缓存、当场失败也走这里，
--- 免得调用方 `job = source:xxx(..., cb)` 在 cb 里看到还没赋值的 job。
---@param cb function
---@return { cancel: fun() }
function SourceBase.defer(cb, ...)
    local args, cancelled = { n = select("#", ...), ... }, false
    require("ui/uimanager"):nextTick(function()
        if not cancelled then require("ui.guard").call("source callback", cb, unpack(args, 1, args.n)) end
    end)
    return { cancel = function() cancelled = true end }
end

--- 下一帧回调一份 skipped 的 SyncResult（该域不支持 / 无事可做）。
---@param cb fun(result: SyncResult)
---@param reason string
---@return { cancel: fun() }
function SourceBase.skipped(cb, reason)
    return SourceBase.defer(cb, { pulled = 0, pushed = 0, hidden = 0, conflicts = 0, skipped = true, reason = reason })
end

--- 返回默认全 false 能力集。
---@return SourceCapabilities
function SourceBase:capabilities()
    return { scrape = false, edit = false, stats_pull = false }
end

--- 是否已配置。
---@return boolean
function SourceBase:configured()
    return false
end

--- 关闭数据源并释放资源（基类空操作）。
function SourceBase:close() end

--- 本地优先删除：清本地缓存 + 打墓碑即算删成功，离线也一样。远端真删归书架同步
--- （`syncBooksAsync` 推脏行，成功后 `BookDB.remove` 撕墓碑）；已连网就顺手 `pushDirty` 入队，不弹联网。
--- 走队列而不直接调同步：同源推脏按 key 只留一条，失败退避重试，不和别的推脏并发。
--- 没有远端删除接口的源（番茄）墓碑一直留着，书在月读里隐藏，reconcile 不会复活它。
---@param identity BookIdentity
---@param cb fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }
function SourceBase:deleteBookAsync(identity, cb)
    if not require("book.store").markDeleted(self.id, identity.stable_id) then
        return SourceBase.defer(cb, false, _("删除本书失败"))
    end
    if self:configured() and require("ui/network/manager"):isConnected() then
        self:pushDirty()
    end
    return SourceBase.defer(cb, true)
end

--- 本源各域的脏行，按推送顺序：书架、笔记、统计，进度最后（微信时长上报会写云端位置，
--- 最后落地的必须是精确进度）。只列有脏行的域：书架没脏行就不调用，免得走成全量 pull。
---@param id SourceId
---@return string[] 同步方法名
local function dirtyDomains(id)
    local out = {}
    if #require("book.books_db").unsynced(id) > 0 then out[#out + 1] = "syncBooksAsync" end
    if require("book.note_db").hasUnsynced(id) then out[#out + 1] = "syncNotesAsync" end
    if #require("book.stats_db").unsyncedBySource(id, 1) > 0 then out[#out + 1] = "syncStatsAsync" end
    if #require("book.progress_db").unsynced(id) > 0 then out[#out + 1] = "syncProgressAsync" end
    return out
end

--- 本源有没有待推的脏行；只查库，不需要源实例。
---@param id SourceId
---@return boolean
function SourceBase.hasDirty(id)
    return #dirtyDomains(id) > 0
end

--- 推本源脏行，作为 sync 类后台任务入队（key 按源唯一，同源只留一条）。
--- 休眠中断、断网失败由队列放回等待并续跑；联网时失败退避重试。某一域失败不影响后面的域。
--- main 在启动、唤醒、联网时对有脏行的启用源调用：Wi-Fi 常开时 KOReader 不再发 NetworkConnected，
--- 只靠联网事件，失败重试和上次遗留的脏行会一直等着。
function SourceBase:pushDirty()
    require("workers.tasks").enqueue{
        key = "dirty\0" .. self.id,
        kind = "sync",
        title = self.name,
        restartable = true,
        run = function(report, done)
            local domains, index, failed, job = dirtyDomains(self.id), 0, nil, nil
            local cancelled = false
            local function nextDomain()
                if cancelled then return end
                index = index + 1
                local method = domains[index]
                if not method then return done({ ok = failed == nil, err = failed }) end
                report(_("正在上传本地改动"), index, #domains)
                job = self[method](self, { dirty_only = true }, function(result, err)
                    -- dirty_only 下推送失败不算整域失败，只记在 push_error；对推脏来说那就是失败。
                    err = result and result.push_error or err
                    if not result or result.push_error then
                        logger.warn("book dirty sync failed", self.id, method, err)
                        failed = failed or err or method
                    end
                    nextDomain()
                end)
            end
            nextDomain()
            return { cancel = function()
                cancelled = true
                if job and job.cancel then job:cancel() end
            end }
        end,
        retryable = function(result) return not result.ok end,
    }
end

--- 业务事件，调用方直接对属主源调用；基类空操作，源按需覆盖。事件清单：
---   page_changed      — 翻页（仅源身份书籍），payload = { identity, page, total_pages, percent, position }
---   chapter_changed   — 按章会话开读章节（含首章），payload = { identity, position }
---   reading_stopped   — 关书 / 休眠，payload = { identity }；阅读中起的定时任务在这里停
---   reading_resumed   — 阅读中唤醒，payload = { identity, position }；休眠停掉的定时任务在这里重启
---   book_meta_changed — 编辑 / 刮削已写库，payload = { identity, cover }（cover=封面换过）；
---     有远端的源立即上行这本书（local WebDAV 写书目条目 + 传封面）
--- 桌面打开 / 图书馆刷新的书架与统计同步不走这里，见 desktop.sync。
---@param _event string 事件名
---@param _payload table|nil 事件载荷，含义随事件而定
function SourceBase:onEvent(_event, _payload) end

--- 默认书架同步：无远端书架。远端源覆盖，local 覆盖为扫盘。
---@param _opts { force?: boolean, dirty_only?: boolean }|nil
---@param cb fun(result: SyncResult|nil, err: any)
---@return { cancel: fun() }
function SourceBase:syncBooksAsync(_opts, cb)
    return SourceBase.skipped(cb, "unsupported")
end

---@param opts { identity?: BookIdentity, dirty_only?: boolean }|nil
---@param cb fun(result: SyncResult|nil, err: any)
---@return table
function SourceBase:syncProgressAsync(opts, cb)
    return require("book.progress").syncAsync(self, opts, cb)
end

---@param opts { identity?: BookIdentity, dirty_only?: boolean }|nil
---@param cb fun(result: SyncResult|nil, err: any)
---@return table
function SourceBase:syncNotesAsync(opts, cb)
    return require("book.note").syncAsync(self, opts, cb)
end

---@param opts table|nil
---@param cb fun(result: SyncResult|nil, err: any)
---@return table
function SourceBase:syncStatsAsync(opts, cb)
    return require("book.stats").syncAsync(self, opts, cb)
end

--- 默认封面：书库 `books.cover` 里的公开 URL。图书馆列表行不带 cover，只能按身份查库。
--- 需要鉴权头或本地提取的源自己覆盖。
---@param identity BookIdentity
---@return BookCoverRequest|nil, string|nil
function SourceBase:coverRequest(identity)
    local url = identity.cover
    if type(url) ~= "string" or url == "" then
        local row = require("book.books_db").get(self.id, identity.stable_id)
        url = row and row.cover
    end
    if type(url) ~= "string" or not url:match("^https?://") then
        return nil, _("无封面")
    end
    return { url = url }
end

SourceBase.SourceCapabilities = SourceCapabilities
return SourceBase
