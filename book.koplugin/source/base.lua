--[[--
数据源运行时基类。

各适配器继承本类，只覆盖自己支持的传输方法。
四类同步中不支持的方向异步成功跳过；所有查询默认读取本地 catalog。

@module koplugin.book.source.base
@see types.book_source
--]]

local SourceCapabilities = require("types.book_source").SourceCapabilities
local _ = require("gettext")

---@class SourceBase : BookSource
---@field id SourceId
---@field name string|nil
---@field type BookSourceType
local SourceBase = {}
SourceBase.__index = SourceBase

-- 首页重新可见时允许检查一次书架；具体同步和网络缓存由各源决定。
local BOOKS_REFRESH_INTERVAL = 5 * 60

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

--- 插件生命周期事件通知。桌面打开默认后台同步书架，各源可追加行为。
--- 事件清单：
---   reader_open     — Reader 实例创建（Reader 侧插件 init）
---   document_close  — 关闭文档
---   chapter_changed — 按章会话切换章节，payload = { identity }
---   fm_open         — FileManager 主界面显示
---   desktop_open    — Book 桌面打开并可见，payload = Desktop 实例
---   home_open       — 用户进入首页；源侧按节流策略检查书架
---   library_refresh_request — 用户在图书馆点击刷新，要求源强制刷新书架
---   suspend         — 设备休眠前（有打开文档时）
---   network_connected — 网络恢复，源可重试持久化上报队列
---   stats_sync_request — 用户请求同步阅读统计，源决定 pull/push 和联网策略
---   page_changed    — 翻页（仅源身份书籍），payload = { identity, page, total_pages, percent }
---   book_info_request — 阅读面板详情页请求书籍信息，payload = { identity, book, refresh }
---     （源可拉最新详情写 Store.rememberMany 后调 refresh() 重绘面板；基类空操作即可）
local function syncDesktopBooks(self, desktop, opts)
    if type(desktop) ~= "table" or desktop._closed then return end
    if desktop._books_sync_pending and not (opts and opts.force) then return end
    if desktop._books_sync_cancel and desktop._books_sync_cancel.cancel then
        desktop._books_sync_cancel:cancel()
    end
    desktop._books_sync_pending = true
    local request = {}
    desktop._books_sync_request = request
    local job = self:syncBooksAsync(opts, function(result, err)
        if desktop._books_sync_request ~= request then return end
        desktop._books_sync_cancel = nil
        desktop._books_sync_pending = false
        local wake_home = desktop._home_waiting_sync
        desktop._home_waiting_sync = nil
        if desktop._closed or desktop.source ~= self then return end
        if not result then
            require("logger").warn("book shelf sync failed", self.id, err)
            desktop:invalidateHome()
            if desktop.tab == "library" then
                desktop._library_state = { books = {}, err = err or _("同步失败") }
                desktop:rebuild()
            end
            return
        end
        -- 源自己的节流命中表示本地数据未变，不要无意义重建整页。
        if result.skipped then
            -- 首页可能正在等待这轮同步完成。即使数据未变，也要让它开始读本地书架。
            if wake_home then desktop:invalidateHome() end
            return
        end
        self._books_refresh_at = os.time()
        desktop._library_state = nil
        desktop:invalidateHome()
        if desktop.tab == "library" then desktop:rebuild() end
    end)
    -- 某些源会同步回调；避免把已完成的 job 句柄残留到桌面状态。
    if desktop._books_sync_request == request and desktop._books_sync_pending then
        desktop._books_sync_cancel = job
    end
end

---@param event string 事件名
---@param payload table|nil 事件载荷，含义随事件而定
function SourceBase:onEvent(event, payload)
    if type(payload) ~= "table" then return end
    if self.configured and not self:configured() then return end
    local desktop = payload
    if event == "home_open" then
        if self._books_refresh_at and os.time() - self._books_refresh_at < BOOKS_REFRESH_INTERVAL then
            return
        end
        syncDesktopBooks(self, desktop)
        return
    end
    if event == "library_refresh_request" then
        syncDesktopBooks(self, desktop, { force = true })
        return
    end
    if event ~= "desktop_open" then return end
    -- 首页取最近阅读必须等首轮书架同步落库；否则远端源的封面仍只在
    -- 实例内存缓存里，首屏会先构建出没有封面的卡片且不会自动补图。
    require("book.stats").pullInBackground(self)
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

--- 最近阅读：只读本地 books.last_open（book.catalog）。
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
