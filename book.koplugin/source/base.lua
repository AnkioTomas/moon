--[[--
数据源运行时基类。

各适配器继承本类，只覆盖自己支持的传输方法。
四类同步中不支持的方向异步 skipped；所有查询默认读取本地 catalog。
书架：远端快照 reconcile（pulled）+ 本地脏成员经 add/delete 上行（pushed）。
本地删除只标 deleted；同步时推云端真删。
全量同步：本地优先 push，再 pull。进度 pull 仅开书（冲突让用户选）；笔记有网即推、开书再拉。
脏 progress/notes/stats 的网络恢复重试由 book.sync.retryDirtyAsync 单通道负责，
本类 onEvent("network_connected") 不重复推脏。

@module koplugin.book.source.base
--]]

---@alias SourceId "moon"|"wechat"|"jdread"|"copymanga"|"fanqie"|"local"|string

---@alias BookSourceType
---| '"book"' # 整本文件
---| '"chapter"' # 连续章节阅读

---@class BookSourceMeta
---@field id SourceId
---@field name string
---@field type BookSourceType 阅读形态

--- 能力是用户可用功能，不是「模块里有没有函数」。
--- 仅保留 UI 实际读取的开关；Source 基础契约和阅读形态不放在能力表中。
---@class SourceCapabilities
---@field search boolean 图书馆关键词搜索（BookListOpts.search）
---@field refresh boolean 支持手动强制重扫书库（本地源；opts.force）
---@field scrape boolean 支持把外部元数据写入本地书籍记录（仅 local 为 true；wechat/moon 明确 false）
---@field edit boolean 支持编辑展示元信息（仅 local 为 true；wechat/moon 明确 false）
---@field insight boolean 阅读洞察 / 统计页（readingInsightAsync）
---@field stats_pull boolean 是否从远端拉取阅读统计并写入本地 reading_stats（各源自决映射与替换策略）
---@field cacheAllChaptersAsync fun(identity: BookIdentity, on_progress: function|nil, cb: function)|nil 章节模式全本缓存

--- 图书馆筛选项与分类索引。
---@class BookFiltersResult
---@field data { category: string[]|nil, category_counts: { category: string, count: integer }[]|nil, series: string[]|nil, series_counts: { series: string, count: integer }[]|nil, read_counts: { status: string, count: integer }[]|nil, downloaded_count: integer|nil, source_counts: { source_id: string, name: string, count: integer }[]|nil }|nil

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
---@field mode '"synced"'|'"all_synced"'|'"prefix"'|'"ranges"' all_synced=全量快照，删除该源全部已同步行
---@field stable_prefixes string[]|nil mode=prefix 时生效
---@field ranges BookStatsPullReplaceRange[]|nil mode=ranges 时按各前缀的独立时间窗口清理

--- pullStatsAsync 回包：纯数组为追加去重；带 replace 为云端优先覆盖入库。
---@class BookStatsPullResult
---@field rows BookStatsRow[]
---@field replace BookStatsPullReplace|nil

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
---@field title string|nil 章节标题
---@field html string|nil HTML/XHTML 正文片段（优先）
---@field text string|nil 纯文本（无 html 时由宿主转段落）

--- 统一数据源实例接口。
--- IO 方法一律异步：XxxAsync(...) 经 cb(data, err) 回传，返回值是可取消 job 或 nil；
--- 同步只保留无 IO 的元信息与本地描述方法（capabilities / configured / coverRequest 等）。
---
--- 本地唯一入口：书架、筛选、书架搜索、进度、笔记和统计查询只读 SQLite。
--- 四个 sync*Async 按源与各自云端双向收敛；打开书和正文下载仍走源协议。
--- 不支持的域异步 skipped（不失败）。探测：progress=get+put；notes=push+pull；
--- stats=pushStatsAsync +（pull 另需 capabilities.stats_pull）。
---
--- 书架：远端快照 reconcile + 本地独有成员经 addToShelf 上行（wechat/jdread）；
--- 删除经 deleteBookAsync。local 扫盘；moon 无 add API（list/delete）。
---@class BookSource
---@field id SourceId|nil 源标识
---@field name string|nil 展示名
---@field type BookSourceType 阅读形态
---@field onEvent fun(self: BookSource, event: string, payload: table|nil)|nil 生命周期事件（见 source.base 注释）
---@field capabilities fun(self: BookSource): SourceCapabilities 能力表
---@field configured fun(self: BookSource): boolean 是否已配置到可请求
---@field clearCaches fun(self: BookSource) 清空源侧缓存
---@field close fun(self: BookSource)|nil 释放资源
---@field syncBooksAsync fun(self: BookSource, opts: { force?: boolean, dirty_only?: boolean }|nil, cb: fun(result: SyncResult|nil, err: any)): table|nil 双向收敛书架；dirty_only 只推本地删/加
---@field syncProgressAsync fun(self: BookSource, opts: { identity?: BookIdentity, dirty_only?: boolean }|nil, cb: fun(result: SyncResult|nil, err: any)): table|nil 双向收敛进度
---@field syncNotesAsync fun(self: BookSource, opts: { identity?: BookIdentity, dirty_only?: boolean }|nil, cb: fun(result: SyncResult|nil, err: any)): table|nil 双向收敛笔记
---@field cleanAnnotations fun(self: BookSource, items: table[], total_pages: integer|nil): table[]|nil 清洗并透传源私有注解字段
---@field prepareLocalAnnotations fun(self: BookSource, previous: table[], current: table[]): table[]|nil 根据源协议生成更新/删除状态
---@field mergeAnnotations fun(self: BookSource, remote: table[], current: table[], paging: boolean|nil, authoritative: boolean): table[]|nil 按源身份语义合并注解
---@field syncStatsAsync fun(self: BookSource, opts: { dirty_only?: boolean }|nil, cb: fun(result: SyncResult|nil, err: any)): table|nil 双向收敛统计
---@field deleteBookAsync fun(self: BookSource, identity: BookIdentity, cb: fun(ok: boolean, err: string|nil)): table|nil 删除源拥有的书籍（在线源应同步云端）
---@field listLibraryAsync fun(self: BookSource, opts: BookListOpts|nil, cb: fun(data: BookListResult|nil, err: string|nil)): table|nil 图书馆列表
---@field recentBooksAsync fun(self: BookSource, limit: number|nil, cb: fun(data: BookListResult|nil, err: string|nil)): table|nil 最近阅读（默认读本地库）
---@field filtersAsync fun(self: BookSource, cb: fun(data: BookFiltersResult|nil, err: string|nil)): table|nil 筛选项
---@field readingInsightAsync fun(self: BookSource, cb: fun(data: BookInsightResult|nil, err: string|nil)): table|nil 阅读洞察
---@field getDetailAsync fun(self: BookSource, identity: BookIdentity, cb: fun(data: Book|nil, err: string|nil)): table|nil 书籍详情
---@field openBookAsync fun(self: BookSource, identity: BookIdentity, opts: table|nil, cb: fun(path: string|nil, err: string|nil)): table|nil 根据书籍身份解析、落盘并登记物理文档；按章源通过 opts.chapter_idx 指定章节；取消后不回调
---@field loadTocAsync fun(self: BookSource, identity: BookIdentity, cb: fun(toc: BookChapter[]|nil, err: string|nil)): table|nil 拉取并持久化章节目录
---@field prefetchChaptersAsync fun(self: BookSource, identity: BookIdentity, toc: BookChapter[], from_idx: integer, count: integer, cb: fun(cached: integer, total: integer, failed: integer, err: any)|nil): table|nil 阅读期预取后续章节
---@field getProgressAsync fun(self: BookSource, identity: BookIdentity, cb: fun(data: ProgressPosition|nil, err: string|nil, meta: table|nil)): table|nil 拉取远端进度；meta.empty 表示远端无记录
---@field putProgressAsync fun(self: BookSource, identity: BookIdentity, pos: ProgressPosition, cb: fun(ok: boolean|nil, err: string|nil)): table|nil 推送进度
---@field coverRequest fun(self: BookSource, identity: BookIdentity): (BookCoverRequest|nil, string|nil) 封面请求描述（纯构造，无 IO）
---@field importBookAsync fun(self: BookSource, local_path: string, filename: string, cb: fun(ok: boolean|nil, err: string|nil)): table|nil Z-Library 导入目标（local 移入）
---@field replaceBook fun(self: BookSource, temp_path: string, stable_id: string): (string|nil, string|nil)|nil 本地转换后替换原书（仅 local）
---@field pushStatsAsync fun(self: BookSource, rows: BookStatsRow[], cb: fun(data: BookStatsPushResult|nil, err: string|nil)): table|nil 上报领域统计记录；协议细节由源处理
---@field pullStatsAsync fun(self: BookSource, cb: fun(result: BookStatsRow[]|BookStatsPullResult|nil, err: string|nil)): table|nil 拉取领域统计记录（可选 replace 覆盖策略）
---@field pushNotesAsync fun(self: BookSource, identity: BookIdentity, annotations: table[], cb: fun(data: table|nil, err: string|nil)): table|nil 上传划线/书签
---@field pullNotesAsync fun(self: BookSource, identity: BookIdentity, cb: fun(data: table[]|nil, err: string|nil, meta: table|nil)): table|nil 拉取划线/书签
---@field localizeAnnotations fun(self: BookSource, document: table|nil, annotations: table[], html_path: string|nil, current: table[]|nil): table[]|nil 按章 HTML 把远端划线定位到本地 xpointer
---@field cacheAllChaptersAsync fun(self: BookSource, identity: BookIdentity, on_progress: function|nil, cb: function): table|nil 章节模式全本缓存
---@field isTocCurrent fun(self: BookSource, toc: BookChapter[]|nil): boolean|nil 本地目录缓存是否仍有效
---@field refreshTocAsync fun(self: BookSource, identity: BookIdentity, cb: fun(toc: BookChapter[]|nil, err: string|nil)): table|nil 强制刷新目录

local logger = require("utils.log")
local _ = require("gettext")

local SourceCapabilities = {}

--- 返回全 false 的默认能力表。
---@return SourceCapabilities
function SourceCapabilities.defaults()
    return {
        search = false,
        refresh = false,
        scrape = false,
        edit = false,
        insight = false,
        stats_pull = false,
    }
end

--- 源是否将远端阅读统计同步入库（UI 与 book.stats 统一入口）。
---@param source BookSource|nil
---@return boolean
function SourceCapabilities.supportsStatsPull(source)
    if not source or type(source.capabilities) ~= "function" then
        return false
    end
    return source:capabilities().stats_pull == true
end

--- 源是否允许刮削（UI 与 scrape 模块统一入口）。
---@param source BookSource|nil
---@return boolean
function SourceCapabilities.supportsScrape(source)
    if not source or type(source.capabilities) ~= "function" then
        return false
    end
    return source:capabilities().scrape == true
end

--- 源是否允许编辑展示元信息（UI 统一入口）。
---@param source BookSource|nil
---@return boolean
function SourceCapabilities.supportsEdit(source)
    if not source or type(source.capabilities) ~= "function" then
        return false
    end
    return source:capabilities().edit == true
end

---@class SourceBase : BookSource
---@field _books_refresh_at number|nil 最近一次书架同步完成时间
---@field _stats_refresh_at number|nil 最近一次统计同步尝试时间
local SourceBase = {}
SourceBase.__index = SourceBase

-- 首页重新可见时允许检查一次书架；具体同步和网络缓存由各源决定。
local BOOKS_REFRESH_INTERVAL = 5 * 60
local STATS_REFRESH_INTERVAL = 5 * 60

--- 返回默认全 false 能力集。
---@return SourceCapabilities
function SourceBase:capabilities()
    return SourceCapabilities.defaults()
end

--- 是否已配置。
---@return boolean
function SourceBase:configured()
    return false
end

--- 清空数据源侧缓存（基类空操作）。
function SourceBase:clearCaches() end

--- 关闭数据源并释放资源（基类空操作）。
function SourceBase:close() end

--- 删除源拥有的书籍；默认源不提供删除实现。
---@param _identity BookIdentity
---@param cb fun(ok: boolean, err: string|nil)
---@return table|nil
function SourceBase:deleteBookAsync(_identity, cb)
    require("ui/uimanager"):nextTick(function()
        cb(false, _("当前数据源不支持删除本书"))
    end)
    return nil
end

--- 插件生命周期事件通知。桌面打开默认后台同步书架，各源可追加行为。
--- 事件清单：
---   reader_open     — Reader 实例创建（Reader 侧插件 init）
---   document_close  — 关闭文档
---   chapter_changed — 按章会话开读章节（含首章），payload = { identity, position }
---   fm_open         — FileManager 主界面显示
---   desktop_open    — 月读桌面打开并可见，payload = Desktop 实例
---   desktop_resume  — 月读桌面从休眠恢复，payload = Desktop 实例
---   home_open       — 用户进入首页；源侧按节流策略检查书架
---   library_refresh_request — 用户在图书馆点击刷新，要求源强制刷新书架
---   suspend         — 设备休眠前（有打开文档时）
---   network_connected — 网络恢复（脏重试由 Sync.retryDirtyAsync 负责，基类不重复推）
---   page_changed    — 翻页（仅源身份书籍），payload = { identity, page, total_pages, percent }
---   book_info_request — 阅读面板详情页请求书籍信息，payload = { identity, book, refresh }
---     （源可拉最新详情写 Store.rememberMany 后调 refresh() 重绘面板；基类空操作即可）
local function syncDesktopBooks(self, desktop, opts)
    if type(desktop) ~= "table" or desktop.lifecycle.state == "Destroy" then return end
    if desktop._books_sync_pending and not (opts and opts.force) then
        logger.dbg("book shelf refresh skipped", self.id, "pending")
        return
    end
    if desktop._books_sync_cancel and desktop._books_sync_cancel.cancel then
        logger.dbg("book shelf refresh cancel previous", self.id)
        desktop._books_sync_cancel:cancel()
    end
    logger.dbg("book shelf refresh start", self.id, opts and opts.force and "forced" or "background")
    desktop._books_sync_pending = true
    local request = {}
    desktop._books_sync_request = request
    local job = self:syncBooksAsync(opts, function(result, err)
        if desktop._books_sync_request ~= request then
            logger.dbg("book shelf refresh result dropped", self.id, "stale")
            return
        end
        desktop._books_sync_cancel = nil
        desktop._books_sync_pending = false
        if desktop.lifecycle.state == "Destroy" or desktop.source ~= self then return end
        if not result then
            logger.warn("book shelf sync failed", self.id, err)
            desktop:onEvent("home_refresh", "shelf_sync_failed")
            if desktop.tab == "library" and desktop.library then
                desktop.library.state = { books = {}, err = err or _("同步失败") }
                desktop:updateView()
            end
            return
        end
        -- 源自己的节流命中表示本地数据未变，不要无意义重建整页。
        if result.skipped then
            logger.dbg("book shelf refresh done", self.id, "skipped", result.reason or "")
            return
        end
        logger.dbg("book shelf refresh done", self.id,
            "pulled", tonumber(result.pulled) or 0,
            "pushed", tonumber(result.pushed) or 0,
            "hidden", tonumber(result.hidden) or 0)
        self._books_refresh_at = os.time()
        if desktop.library then desktop.library.state = nil end
        desktop:onEvent("home_refresh", "shelf_sync")
        if desktop.tab == "library" then desktop:updateView() end
    end)
    -- 某些源会同步回调；避免把已完成的 job 句柄残留到桌面状态。
    if desktop._books_sync_request == request and desktop._books_sync_pending then
        desktop._books_sync_cancel = job
    end
end

--- 后台双向同步统计；成功后作废依赖本地 reading_stats 的桌面缓存。
---@param self SourceBase
---@param desktop table
---@param opts { force?: boolean }|nil
local function syncDesktopStats(self, desktop, opts)
    local can_pull = SourceCapabilities.supportsStatsPull(self)
    local can_push = type(self.pushStatsAsync) == "function"
    if not can_pull and not can_push then return end
    if desktop._stats_sync_pending then
        logger.dbg("book stats sync skipped", self.id, "pending")
        return
    end
    if not (opts and opts.force) and self._stats_refresh_at
        and os.time() - self._stats_refresh_at < STATS_REFRESH_INTERVAL then
        logger.dbg("book stats sync skipped", self.id, "throttled")
        return
    end
    logger.dbg("book stats sync start", self.id)
    self._stats_refresh_at = os.time()
    desktop._stats_sync_pending = true
    local request = {}
    desktop._stats_sync_request = request
    local job = self:syncStatsAsync(nil, function(result, err)
        if desktop._stats_sync_request ~= request then return end
        desktop._stats_sync_cancel = nil
        desktop._stats_sync_pending = false
        if desktop.lifecycle.state == "Destroy" or desktop.source ~= self then return end
        if not result then
            logger.warn("book stats sync failed", self.id, err)
            return
        end
        logger.dbg("book stats sync done", self.id,
            "pulled", tonumber(result.pulled) or 0,
            "pushed", tonumber(result.pushed) or 0)
        if not result.skipped then
            if desktop.insight then
                desktop.insight.state = nil
                desktop.insight.loaded = false
            end
            desktop:onEvent("home_refresh", "stats_sync")
            if desktop.tab == "insight" then desktop:updateView() end
        end
    end)
    if desktop._stats_sync_request == request and desktop._stats_sync_pending then
        desktop._stats_sync_cancel = job
    end
end

---@param event string 事件名
---@param payload table|nil 事件载荷，含义随事件而定
function SourceBase:onEvent(event, payload)
    if type(payload) ~= "table" then return end
    if self.configured and not self:configured() then return end
    local desktop = payload
    if event == "home_open" or event == "desktop_resume" then
        syncDesktopStats(self, desktop)
        if self._books_refresh_at and os.time() - self._books_refresh_at < BOOKS_REFRESH_INTERVAL then
            logger.dbg("book shelf refresh skipped", self.id, "throttled")
            return
        end
        syncDesktopBooks(self, desktop)
        return
    end
    if event == "library_refresh_request" then
        syncDesktopStats(self, desktop, { force = true })
        syncDesktopBooks(self, desktop, { force = true })
        return
    end
    if event ~= "desktop_open" then return end
    -- 书架同步在后台进行：首页先读本地数据，成功后由回调刷新封面和元数据。
    syncDesktopStats(self, desktop)
    syncDesktopBooks(self, desktop)
end

--- 默认书架同步：无远端书架。远端源覆盖，local 覆盖为扫盘。
---@param _opts { force?: boolean }|nil
---@param cb fun(result: SyncResult|nil, err: any)
---@return { cancel: fun() }
function SourceBase:syncBooksAsync(_opts, cb)
    local cancelled = false
    require("ui/uimanager"):nextTick(function()
        if cancelled then return end
        cb({
            pulled = 0, pushed = 0, hidden = 0, conflicts = 0,
            skipped = true, reason = "unsupported",
        })
    end)
    return { cancel = function() cancelled = true end }
end

---@param opts { identity?: BookIdentity }|nil
---@param cb fun(result: SyncResult|nil, err: any)
---@return table
function SourceBase:syncProgressAsync(opts, cb)
    return require("book.progress").syncAsync(self, opts, cb)
end

---@param opts { identity?: BookIdentity }|nil
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

--- 最近阅读：仅按本地阅读进度更新时间排序（book.catalog）。
---@param limit number|nil
---@param cb fun(data: BookListResult|nil, err: string|nil)
---@return table|nil
function SourceBase:recentBooksAsync(limit, cb)
    return require("book.catalog").recentBooksAsync(self.id, limit, cb)
end

--- 图书馆查询始终读取本地 catalog。
---@param opts BookListOpts|nil
---@param cb fun(data: BookListResult|nil, err: string|nil)
---@return table|nil
function SourceBase:listLibraryAsync(opts, cb)
    return require("book.catalog").listLibraryAsync(self.id, opts, cb)
end

--- 筛选项始终从本地书籍字段推导。
---@param cb fun(data: BookFiltersResult|nil, err: string|nil)
---@return table|nil
function SourceBase:filtersAsync(cb)
    return require("book.catalog").filtersAsync(self.id, cb)
end

--- 阅读洞察始终聚合本地统计。
---@param cb fun(data: BookInsightResult|nil, err: string|nil)
---@return table|nil
function SourceBase:readingInsightAsync(cb)
    return require("book.catalog").readingInsightAsync(self.id, cb)
end

--- 基类不支持封面请求。
---@param _identity BookIdentity
---@return BookCoverRequest|nil, string|nil
function SourceBase:coverRequest(_identity)
    return nil, _("当前数据源不支持封面")
end

SourceBase.SourceCapabilities = SourceCapabilities
return SourceBase
