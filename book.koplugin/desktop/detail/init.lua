--[[--
书籍详情：全屏主题页，标题栏返回 + Hero 卡片 + 来源内容区 + 最多两行按钮区。
  单页不滚动，「最近几天」用翻页条分页。
  书城预览书（Z-Library / OPDS）未入库：无编辑/统计，hero 不显示简介摘要与进度，完整简介直下，
  底栏「加入书库」；图书馆显示统计及源支持的操作。
  关窗即结束：closed 置位，在飞的书城详情补拉随之取消。

布局：
  +-----------------------------------------------+
  | [<]                                           | TitleBar
  |-----------------------------------------------|
  | +----+  书名                                  |
  | |封面|  作者          ← 点按开始阅读           | bookhero
  | +----+  源名 · 分类 · 系列 / 简介 / 进度条     |
  |                                               |
  | [累计时长] [已读页数] [上次阅读]               | KPI 卡片
  | 最近几天                                       |
  | 08-15  ========····  42分钟                    |
  | [<]            1 / 3                     [>]  | 多于一页才出现
  |                                               |
  | [编辑] [刮削] [下载] [状态] [删除]             | 工具行
  | [██████ 继续阅读 / 开始阅读 ██████]            | 主操作
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
---@field _daily_page integer|nil
---@field _detail_job CancelHandle|nil
---@field updateView fun(self: BookDetailPage) 整页重建，见 detail/layout.lua
local Detail = Modal:extend{
    name = "book_detail",
    covers_fullscreen = true,
    mask = false,
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
    self:fetchMissingIntro()
end

--- 库内书没有简介（书架快照常不带）且在线时，向属主源要一次详情；源负责落库，这里只重读重画。
--- 离线不请求，不弹联网。
function Detail:fetchMissingIntro()
    local book = self.book
    if self.origin ~= "library" or not (book.source_id and book.stable_id) then return end
    local row = require("book.books_db").get(book.source_id, book.stable_id)
    if not row or row.intro then return end
    local owner = require("desktop.detail.common").bookOwnerSource(book, self.source)
    if not (owner and owner.getDetailAsync and require("ui/network/manager"):isConnected()) then return end
    local identity = { source_id = book.source_id, stable_id = book.stable_id, source = owner, book = row }
    self._detail_job = owner:getDetailAsync(identity, function(detail)
        self._detail_job = nil
        if self.closed or not detail then return end
        local fresh = require("book.books_db").get(book.source_id, book.stable_id)
        if not (fresh and fresh.intro) then return end
        -- 只并简介 / 作者：self.book 是书架列表项，带进度等列表专有字段，不能整行换掉。
        book.intro, book.authors = fresh.intro, fresh.authors or book.authors
        self:refresh()
    end)
end

--- 重建并重画自己。
function Detail:refresh()
    self:updateView()
    UIManager:setDirty(self, "ui")
end

--- 读本机阅读统计（汇总 + 最近 N 天）。书城预览书未读过，无本机数据可查，直接跳过。
function Detail:loadStats()
    local book = self.book
    if self.origin == "store" then
        return
    end
    local StatsDB = require("book.stats_db")
    self._stats = StatsDB.summaryByBook(book.source_id, book.stable_id)
    self._daily = StatsDB.dailyByBook(book.source_id, book.stable_id, 30)
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
