--[[--
数据源运行时基类。

各适配器继承本类，只覆盖自己支持的传输方法。
四类同步中不支持的方向异步 skipped；所有查询默认读取本地 catalog。
书架：远端快照 reconcile（pulled）+ 本地脏成员经 add/delete 上行（pushed）。
本地删除只标 deleted；同步时推云端真删。
全量同步：本地优先 push，再 pull。进度 pull 仅开书（冲突让用户选）；笔记有网即推、开书再拉。
网络恢复由本源 onNetworkConnected 只推自己的脏行：书架、笔记、统计，进度最后。

@module koplugin.book.source.base
--]]

---@alias SourceId "moon"|"wechat"|"jdread"|"copymanga"|"fanqie"|"local"|"kindle"|string

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
---@field scrape boolean 支持把外部元数据写入本地书籍记录（仅 local 为 true）
---@field edit boolean 支持编辑展示元信息（仅 local 为 true）
---@field stats_pull boolean 是否从远端拉取阅读统计并写入本地 reading_stats（各源自决映射与替换策略）

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
---@field mode '"all_synced"'|'"ranges"'|nil all_synced=全量快照，删除该源全部已同步行；缺省=按本批时间窗口清理已同步合成行
---@field ranges BookStatsPullReplaceRange[]|nil mode=ranges 时按各前缀的独立时间窗口清理
---@field books string[]|nil 按 stable_id 精确整本替换 book_day / book_total（与 mode 无关）

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
---@field onCreate fun(self: BookSource, plugin: BookPlugin) 插件 init
---@field onSuspend fun(self: BookSource, plugin: BookPlugin) 休眠前
---@field onResume fun(self: BookSource, plugin: BookPlugin) 唤醒后
---@field onExit fun(self: BookSource, plugin: BookPlugin) KOReader 退出
---@field onEvent fun(self: BookSource, event: string, payload: table|nil) 业务事件（见 SourceBase:onEvent）
---@field capabilities fun(self: BookSource): SourceCapabilities 能力表
---@field configured fun(self: BookSource): boolean 是否已配置到可请求
---@field clearCaches fun(self: BookSource) 清空源侧缓存
---@field close fun(self: BookSource)|nil 释放资源
---@field syncBooksAsync fun(self: BookSource, opts: { force?: boolean, dirty_only?: boolean, on_progress?: fun(text: string, done: integer|nil, total: integer|nil) }|nil, cb: fun(result: SyncResult|nil, err: any)): table|nil 双向收敛书架；dirty_only 只推本地删/加；on_progress 在真实步骤（拉取/上传/写库…）处上报，done/total 为该步计数
---@field syncProgressAsync fun(self: BookSource, opts: { identity?: BookIdentity, dirty_only?: boolean }|nil, cb: fun(result: SyncResult|nil, err: any)): table|nil 双向收敛进度
---@field syncNotesAsync fun(self: BookSource, opts: { identity?: BookIdentity, dirty_only?: boolean }|nil, cb: fun(result: SyncResult|nil, err: any)): table|nil 双向收敛笔记
---@field cleanAnnotations fun(self: BookSource, items: table[], total_pages: integer|nil): table[]|nil 清洗并透传源私有注解字段
---@field prepareLocalAnnotations fun(self: BookSource, previous: table[], current: table[]): table[]|nil 根据源协议生成更新/删除状态
---@field mergeAnnotations fun(self: BookSource, remote: table[], current: table[], paging: boolean|nil, authoritative: boolean): table[]|nil 按源身份语义合并注解
---@field syncStatsAsync fun(self: BookSource, opts: { dirty_only?: boolean }|nil, cb: fun(result: SyncResult|nil, err: any)): table|nil 双向收敛统计
---@field deleteBookAsync fun(self: BookSource, identity: BookIdentity, cb: fun(ok: boolean, err: string|nil)): table|nil 删除源拥有的书籍（在线源应同步云端）
---@field listLibraryAsync fun(self: BookSource, opts: BookListOpts|nil, cb: fun(data: BookListResult|nil, err: string|nil)): table|nil 图书馆列表
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
---@field replaceBookAsync fun(self: BookSource, temp_path: string, stable_id: string, cb: fun(new_path: string|nil, err: string|nil)): CancelHandle|nil 本地转换后替换原书（仅 local，含 WebDAV 书）
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
        scrape = false,
        edit = false,
        stats_pull = false,
    }
end

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

-- 插件生命周期（名字即 KOReader 事件名）：main.lua 转发给所有启用源（混合模式下都在用），参数为插件实例，默认空操作；要不要响应由源自己判断。
-- 旧书的属主源可能不是当前源，阅读期收尾走 reader/session，不靠这里。

---@param _plugin BookPlugin
function SourceBase:onCreate(_plugin) end

---@param _plugin BookPlugin
function SourceBase:onSuspend(_plugin) end

---@param _plugin BookPlugin
function SourceBase:onResume(_plugin) end

---@param _plugin BookPlugin
function SourceBase:onExit(_plugin) end

--- 网络恢复：只推本源脏行。进度放在统计之后——微信时长上报会写云端位置，最后落地的必须是精确进度。
--- 书架没有脏行就不调用，避免走成全量 pull。某一域失败不影响后面的域。
---@param _plugin BookPlugin
function SourceBase:onNetworkConnected(_plugin)
    local id = self.id
    local steps = {}
    if #require("book.books_db").unsynced(id) > 0 then
        steps[#steps + 1] = function(cb)
            return self:syncBooksAsync({ dirty_only = true }, cb)
        end
    end
    if #require("book.note_db").unsynced(id) > 0 then
        steps[#steps + 1] = function(cb)
            return self:syncNotesAsync({ dirty_only = true }, cb)
        end
    end
    if #require("book.stats_db").unsyncedBySource(id) > 0 then
        steps[#steps + 1] = function(cb)
            return self:syncStatsAsync({ dirty_only = true }, cb)
        end
    end
    if #require("book.progress_db").unsynced(id) > 0 then
        steps[#steps + 1] = function(cb)
            return self:syncProgressAsync({ dirty_only = true }, cb)
        end
    end
    local index = 1
    local function nextStep()
        local step = steps[index]
        if not step then return end
        index = index + 1
        step(function(result, err)
            if not result then logger.warn("book dirty sync failed", id, err) end
            nextStep()
        end)
    end
    nextStep()
end

--- 业务事件，调用方直接对属主源调用；基类空操作，源按需覆盖。事件清单：
---   page_changed      — 翻页（仅源身份书籍），payload = { identity, page, total_pages, percent }
---   chapter_changed   — 按章会话开读章节（含首章），payload = { identity, position }
---   book_meta_changed — 编辑 / 刮削已写库，payload = { identity, cover }（cover=封面换过）；
---     有远端的源立即上行这本书（local WebDAV 写书目条目 + 传封面）
---   book_info_request — 阅读面板详情页请求书籍信息，payload = { identity, book, refresh }
---     （源可拉最新详情写 Store.rememberMany 后调 refresh() 重绘面板）
--- 桌面打开 / 图书馆刷新的书架与统计同步不走这里，见 desktop.sync。
---@param _event string 事件名
---@param _payload table|nil 事件载荷，含义随事件而定
function SourceBase:onEvent(_event, _payload) end

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
