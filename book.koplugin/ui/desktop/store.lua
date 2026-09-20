--[[--
Z-Library Tab：浏览 / 搜索目录，下载后导入本地书库。

布局（同 Library.build）：
  +-----------------------------------------------+
  | [🔍搜索] [清除]                     共N       |
  | +----+ +----+ +----+ +----+                   |
  | |封面| |封面| |封面| |封面|                   |
  | |书名| |书名| |书名| |书名|                   |
  | +----+ +----+ +----+ +----+                   |
  |  |«  ‹   Page N of M   ›  »|                  |
  +-----------------------------------------------+

@module koplugin.book.ui.store
--]]

local Device = require("device")
local Library = require("ui.desktop.library")
local BookStore = require("book.store")
local UI = require("ui.components.bookui")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local View = require("ui.view")
local Screen = Device.screen

---@class BookStorePage : View
---@field desktop BookDesktop
---@field state table|nil
---@field books table[]|nil
---@field fetch_cancel CancelHandle|nil
---@field search string|nil
---@field page number
---@field page_size number
---@field total number
---@field cancel fun(self: BookStorePage)
---@field showSearch fun(self: BookStorePage)
---@field build fun(self: BookStorePage, ctx: table, state: table, opts: table|nil): table
local Store = {}
Store.__index = Store
setmetatable(Store, View)

local MAX_RESULTS = 200

function Store:new(opts)
    opts = opts or {}
    opts.page = opts.page or 1
    opts.page_size = opts.page_size or 12
    opts.total = opts.total or 0
    return View.new(self, opts)
end

function Store:cancel()
    if self.fetch_cancel then
        self.fetch_cancel:cancel()
        self.fetch_cancel = nil
    end
end

function Store:reset()
    self:cancel()
    self.state = nil
    self.books = nil
    self.search = nil
    self.page = 1
    self.total = 0
end

function Store:onCancel()
    self:cancel()
end

function Store:onPause()
    self:cancel()
end

function Store:onDestroy()
    self:cancel()
end

---@param event string
---@param payload table|nil
function Store:onEvent(event, payload)
    if event == "source_changed" then
        self:reset()
        return
    end
    if event ~= "swipe" or type(payload) ~= "table" then return end
    if payload.direction == "west" then
        self:gotoPage((self.page or 1) + 1)
    elseif payload.direction == "east" then
        self:gotoPage((self.page or 1) - 1)
    end
end

--- 从已加载结果中切出当前 UI 页。
---@return table
function Store:pageBooks()
    local all = self.books or {}
    local page_size = self.page_size or 1
    local first = ((self.page or 1) - 1) * page_size + 1
    local books = {}
    for i = first, math.min(#all, first + page_size - 1) do
        books[#books + 1] = all[i]
    end
    return books
end

--- 复用图书馆网格构建 Z-Library 页。
---@param ctx table
---@param state table
---@param opts table|nil
---@return table
function Store:build(ctx, state, opts)
    opts = opts or {}
    opts.loading_text = opts.loading_text or _("加载中…")
    opts.empty_text = opts.empty_text or _("Z站暂无内容")
    opts.search_only = true
    opts.show_status = false
    opts.on_search = opts.on_search or function()
        self:showSearch()
    end
    opts.on_clear = opts.on_clear or function()
        self:applySearch("")
    end
    local library = ctx.desktop and ctx.desktop.library or Library:new{ desktop = ctx.desktop, name = "library" }
    return library:build(ctx, state, opts)
end

--- 应用搜索；与图书馆筛选状态分开保存。
---@param query string|nil
function Store:applySearch(query)
    local desktop = self.desktop
    self:cancel()
    self.search = query and query ~= "" and query or nil
    self.page = 1
    self.total = 0
    self.books = nil
    self.state = nil
    desktop.tab = "store"
    self.desktop:updateView()
end

--- 弹出搜索框。
function Store:showSearch()
    local library = self.desktop.library or Library:new{ desktop = self.desktop, name = "library" }
    library:showSearch(function(query)
        self:applySearch(query)
    end, self.search)
end

--- 同步 page_size（与图书馆同网格公式；不碰图书馆实例）。
---@return number
function Store:syncPageSize()
    local desktop = self.desktop
    local width = (desktop.dimen and desktop.dimen.w) or Screen:getWidth()
    local height = type(desktop.contentHeight) == "function"
        and desktop:contentHeight()
        or math.max(1, Screen:getHeight() - UI.barH() - UI.topBarH())
    local m = Library.gridMetrics(width, height)
    self.page_size = math.max(1, m.page_size or 1)
    return self.page_size
end

--- 计算总页数。
---@return number
function Store:pages()
    local ps = self.page_size or 1
    return math.max(1, math.ceil((self.total or 0) / ps))
end

--- 跳转到指定页并重建。
---@param page number
function Store:gotoPage(page)
    page = tonumber(page) or 1
    local pages = self:pages()
    if page < 1 then page = 1 end
    if page > pages then page = pages end
    if page == self.page and self.state then
        return
    end
    self.page = page
    self.state = self.books and { books = self:pageBooks() } or nil
    self.desktop:updateView()
end

--- 异步拉取 Z-Library 列表。
function Store:fetch()
    local desktop = self.desktop
    self:cancel()
    self:syncPageSize()
    local generation = desktop.source_generation or 0
    local search = self.search or ""

    --- 写入错误状态；失败结果不缓存。
    ---@param err string
    local function fail(err)
        if desktop.lifecycle.state == "Destroy" or desktop.tab ~= "store" then return end
        self.books = nil
        self.total = 0
        self.state = { books = {}, err = err }
        self.desktop:updateView()
    end

    local zlib = require("zlib.init")
    self.fetch_cancel = zlib:listStoreAsync({
        page = 1,
        page_size = MAX_RESULTS,
        search = search,
    }, function(res, err)
        if desktop.lifecycle.state == "Destroy" or desktop.tab ~= "store"
            or (desktop.source_generation or 0) ~= generation
            or (self.search or "") ~= search then
            return
        end
        self.fetch_cancel = nil
        if not res then
            fail(err or _("加载失败"))
            return
        end
        local books = {}
        for i = 1, math.min(#(res.data or {}), MAX_RESULTS) do
            books[#books + 1] = res.data[i]
        end
        BookStore.rememberMany(books)
        self.books = books
        self.total = #books
        local pages = self:pages()
        if (self.page or 1) > pages then self.page = pages end
        self.state = { books = self:pageBooks() }
        self.desktop:updateView()
    end)
end

--- Z-Library widget。
---@return table
function Store:updateView()
    local desktop = self.desktop
    local prev_ps = self.page_size
    self:syncPageSize()
    if prev_ps and prev_ps ~= self.page_size then
        self.state = nil
        local pages = self:pages()
        if (self.page or 1) > pages then
            self.page = pages
        end
    end
    local state = self.state
    if not state and self.books then
        state = { books = self:pageBooks() }
        self.state = state
    end
    if not state then
        UIManager:nextTick(function()
            if desktop.lifecycle.state == "Destroy" or desktop.tab ~= "store" then return end
            self:fetch()
        end)
    end
    self.widget = self:build(desktop:ctx(), state or {}, {
        page = self.page,
        pages = self:pages(),
        total = self.total or 0,
        loading_text = _("加载中…"),
        empty_text = _("Z站暂无内容"),
        on_prev = function()
            self:gotoPage((self.page or 1) - 1)
        end,
        on_next = function()
            self:gotoPage((self.page or 1) + 1)
        end,
        on_first = function()
            self:gotoPage(1)
        end,
        on_last = function()
            self:gotoPage(self:pages())
        end,
    })
    return self.widget
end

return Store
