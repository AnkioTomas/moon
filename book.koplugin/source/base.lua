--[[--
数据源运行时基类。

各适配器继承本类，只覆盖自己支持的传输方法。
四类同步中不支持的方向异步成功跳过；所有查询默认读取本地 catalog。

@module koplugin.book.source.base
@see types.book_source
--]]

local SourceCapabilities = require("types.book_source").SourceCapabilities
local logger = require("utils.log")
local _ = require("gettext")

---@class SourceBase : BookSource
---@field id SourceId
---@field name string|nil
---@field type BookSourceType
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
---   chapter_changed — 按章会话切换章节，payload = { identity }
---   fm_open         — FileManager 主界面显示
---   desktop_open    — 月读桌面打开并可见，payload = Desktop 实例
---   desktop_resume  — 月读桌面从休眠恢复，payload = Desktop 实例
---   home_open       — 用户进入首页；源侧按节流策略检查书架
---   library_refresh_request — 用户在图书馆点击刷新，要求源强制刷新书架
---   suspend         — 设备休眠前（有打开文档时）
---   network_connected — 网络恢复，源可重试持久化上报队列
---   page_changed    — 翻页（仅源身份书籍），payload = { identity, page, total_pages, percent }
---   book_info_request — 阅读面板详情页请求书籍信息，payload = { identity, book, refresh }
---     （源可拉最新详情写 Store.rememberMany 后调 refresh() 重绘面板；基类空操作即可）
local function syncDesktopBooks(self, desktop, opts)
    if type(desktop) ~= "table" or desktop._closed then return end
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
        if desktop._closed or desktop.source ~= self then return end
        if not result then
            require("utils.log").warn("book shelf sync failed", self.id, err)
            desktop:refreshHome("shelf_sync_failed")
            if desktop.tab == "library" then
                desktop._library_state = { books = {}, err = err or _("同步失败") }
                desktop:rebuild()
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
        desktop._library_state = nil
        desktop:refreshHome("shelf_sync")
        if desktop.tab == "library" then desktop:rebuild() end
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
        if desktop._closed or desktop.source ~= self then return end
        if not result then
            logger.warn("book stats sync failed", self.id, err)
            return
        end
        logger.dbg("book stats sync done", self.id,
            "pulled", tonumber(result.pulled) or 0,
            "pushed", tonumber(result.pushed) or 0)
        if not result.skipped then
            desktop._insight_state = nil
            desktop._insight_loaded = false
            desktop:refreshHome("stats_sync")
            if desktop.tab == "stats" then desktop:rebuild() end
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

---@param cb function
---@param result table
---@return { cancel: fun() }
local function defer(cb, result)
    local cancelled = false
    require("ui/uimanager"):nextTick(function()
        if not cancelled then cb(result) end
    end)
    return { cancel = function() cancelled = true end }
end

--- 异步回报一个「跳过」的同步结果，供不支持某方向同步的源直接复用。
---@param cb fun(result: SyncResult)
---@return { cancel: fun() }
local function unsupported(cb)
    return defer(cb, {
        pulled = 0, pushed = 0, hidden = 0, conflicts = 0,
        skipped = true, reason = "unsupported",
    })
end

--- 默认书架同步：无远端书架。远端源覆盖，local 覆盖为扫盘。
---@param _opts { force?: boolean }|nil
---@param cb fun(result: SyncResult|nil, err: any)
---@return { cancel: fun() }
function SourceBase:syncBooksAsync(_opts, cb)
    return unsupported(cb)
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

return SourceBase
