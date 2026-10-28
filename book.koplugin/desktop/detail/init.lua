--[[--
书籍详情：全屏主题页，单页不滚动。主操作在头部，次要操作收在标题栏右上角「更多」菜单。
  书城预览书（Z-Library / OPDS）未入库：没有菜单与指标带，主按钮「加入书库」；
  图书馆显示阅读指标（点按看完整阅读记录）及源支持的操作。
  关窗即结束：closed 置位，在飞的书城详情补拉随之取消。

布局：
  +-----------------------------------------------+
  | [<]                                     [...] | TitleBar；[...] 是工具项菜单
  |-----------------------------------------------|
  | +--------+  书名（最多 3 行）                  |
  | |        |  作者                               |
  | |  封面  |  系列 · 分类                        |
  | |  38%   |                                     |
  | |        |  [████ 继续阅读 / 开始阅读 ████]    | 主操作，贴封面底边
  | +--------+  42% ========····  约剩 3小时       |
  |-----------------------------------------------|
  |  12小时 | 356 | 10-12 | 10-20                 | 指标带，点按弹「阅读记录」
  |-----------------------------------------------|
  | 简介 …………………………………………………… 更多 ›         | 截断时点按看全文
  |-----------------------------------------------|
  | 书籍信息  来源 x  格式 x / 大小 x  加入 x       | 两列表格，放不下从末尾丢行
  +-----------------------------------------------+

@module koplugin.book.desktop.detail
--]]

local UIManager = require("ui/uimanager")
local Modal = require("ui.themes.widgets.modal")
local Store = require("book.store")
local storeBackend = require("desktop.detail.common").storeBackend

---@class BookDetailPage : BookThemeModal
---@field book Book|BookDetail|table
---@field plugin BookPlugin|nil
---@field source BookSource|nil
---@field desktop BookDesktop|nil
---@field origin "store"|"library"
---@field closed boolean|nil 关窗后置位；异步回调据此放弃更新
---@field _dirty boolean|nil
---@field _stats table|nil
---@field _daily table|nil
---@field _detail_job CancelHandle|nil
---@field updateView fun(self: BookDetailPage) 整页重建，见 detail/layout.lua
local Detail = Modal:extend{
    name = "book_detail",
    covers_fullscreen = true,
    book = nil,
    plugin = nil,
    source = nil,
    desktop = nil,
}

--- 打开详情页。详情页自己的入口，不要经 Desktop:onEvent 分流。
---@param desktop BookDesktop 所属桌面实例
---@param origin "store"|"library" 详情来源
---@param book table 当前操作或展示的书籍数据
function Detail.open(desktop, origin, book)
    if desktop.detail then desktop.detail:close() end
    if book.source_id and not storeBackend(book) then
        Store.rememberMany({ book })
    end
    local detail
    detail = Detail:new{
        book = book,
        origin = origin,
        plugin = desktop.plugin,
        source = desktop.source,
        desktop = desktop,
        close_callback = function()
            if desktop.detail == detail then desktop.detail = nil end
            if desktop.closed then return end
            -- 书的数据变了（刮削 / 编辑 / 删除）要重建桌面，否则只重画露出来的旧画面。
            if detail._dirty then
                desktop:onEvent("detail_dirty")
                if desktop.tab ~= "home" then desktop:updateView() end
            end
            UIManager:setDirty(desktop, "ui")
        end,
    }
    desktop.detail = detail
    detail:show()
end

function Detail:init()
    Modal.init(self)
    self:loadStats()
    local row = self:mergeStored()
    self:updateView()
    -- OPDS 条目本身就是完整详情，只有 zlib 需要补拉。
    local store = storeBackend(self.book)
    if store then
        if store.getDetailAsync then
            self._detail_job = store.getDetailAsync(self.book, function(detail)
                self._detail_job = nil
                if self.closed or not detail then return end
                self.book = detail
                self:refresh()
            end)
        end
        return
    end
    self:fetchMissingDetail(row)
end

--- 库内书：书架列表行不带扩展元数据，从 books 行并进来。
--- self.book 是书架列表项，带进度等列表专有字段，不能整行换掉。
---@return Book|nil row books 行；书城书 / 未入库返回 nil
function Detail:mergeStored()
    local book = self.book
    if storeBackend(book) or not (book.source_id and book.stable_id) then return nil end
    local BookDB = require("book.books_db")
    local row = BookDB.get(book.source_id, book.stable_id)
    if row then
        book.meta = row.meta
        book.authors, book.intro = row.authors or book.authors, row.intro or book.intro
    end
    return row
end

--- 库内书缺简介，或还没拉过详情（书架快照的扩展元数据常不全）且在线时，向属主源要一次详情；
--- 源负责落库，成功后记 meta.detail_at，之后只靠强制刷新更新。离线不请求，不弹联网。
---@param row Book|nil mergeStored 读到的 books 行
function Detail:fetchMissingDetail(row)
    if not row then return end
    if row.intro and row.intro ~= "" and row.authors and row.authors ~= ""
        and row.meta and row.meta.detail_at then return end
    local BookDB = require("book.books_db")
    local book = self.book
    local owner = require("desktop.detail.common").bookOwnerSource(book, self.source)
    if not (owner and owner.getDetailAsync and require("ui/network/manager"):isConnected()) then return end
    local identity = { source_id = book.source_id, stable_id = book.stable_id, source = owner, book = row }
    self._detail_job = owner:getDetailAsync(identity, function(detail, err)
        self._detail_job = nil
        if self.closed then return end
        if not detail then
            if err then require("utils.log").warn("book detail fetch failed", book.source_id, book.stable_id, err) end
            return
        end
        local fresh = BookDB.get(book.source_id, book.stable_id)
        if not fresh then return end
        if fresh.intro and fresh.intro ~= "" and fresh.authors and fresh.authors ~= "" then
            local at = os.time()
            if BookDB.setMeta({ source_id = book.source_id, stable_id = book.stable_id, meta = { detail_at = at } }, true) then
                fresh.meta = fresh.meta or {}
                fresh.meta.detail_at = at
            else
                require("utils.log").warn("book detail timestamp save failed", book.source_id, book.stable_id)
            end
        end
        book.intro, book.authors, book.meta = fresh.intro or book.intro, fresh.authors or book.authors, fresh.meta
        self:refresh()
    end)
end

--- 重建并重画自己。
function Detail:refresh()
    self:updateView()
    UIManager:setDirty(self, "ui")
end

--- 读本机阅读统计（汇总 + 最近 N 天 + 云端会话）。书城预览书未读过，无本机数据可查，直接跳过。
--- 多卷书（如 Kavita 多卷 series）的统计记在卷行上：由属主源给出要合并的身份，
--- 容器详情页把这些卷的时长 / 页数 / 会话并成一本展示。
function Detail:loadStats()
    local book = self.book
    if self.origin == "store" then
        return
    end
    local StatsDB = require("book.stats_db")
    local ids = { book.stable_id }
    local owner = require("desktop.detail.common").bookOwnerSource(book, self.source)
    if owner and type(owner.statsIdentities) == "function" then
        local more = owner:statsIdentities(book)
        if type(more) == "table" and #more > 0 then ids = more end
    end
    self._stats = StatsDB.summaryByBooks(book.source_id, ids)
    self._daily = StatsDB.dailyByBooks(book.source_id, ids, 30)
    self._sessions = StatsDB.sessionsByBook(book.source_id, ids, 10)
end

--- 刮削/编辑结束后重读 books 行并重画：元数据与封面都只在重建时取，
--- 光 setDirty 只会把旧数据再画一遍。
--- 走到这说明底层数据已变，打脏标记，关闭详情时桌面要清缓存重建而不是纯重画。
function Detail:reload()
    self._dirty = true
    if self.desktop then self.desktop:onEvent("shelf_changed") end
    if self.closed then return end
    local book = self.book
    local row = require("book.books_db").get(book.source_id, book.stable_id)
    if row then
        row.source_id = book.source_id
        row.stable_id = book.stable_id
        self.book = row
    end
    self:refresh()
end

function Detail:onCloseWidget()
    self.closed = true
    if self._detail_job then
        self._detail_job:cancel()
        self._detail_job = nil
    end
    if self.scrape_job then
        self.scrape_job.cancel()
        self.scrape_job = nil
    end
    -- 封面 BlitBuffer 只在 free 时释放。
    local body = self[1] --[[@as WidgetContainer|nil]]
    if body and body.free then body:free() end
    Modal.onCloseWidget(self)
end

require("desktop.detail.actions")(Detail)
require("desktop.detail.editor")(Detail)
require("desktop.detail.content")(Detail)
require("desktop.detail.layout")(Detail)

return Detail
