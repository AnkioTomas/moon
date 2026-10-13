--[[--
书城 Tab（Z-Library / OPDS）：浏览 / 搜索目录，下载后导入本地书库。
后端由 store_id 决定（`store.<store_id>` 提供 listStoreAsync / installAsync）；
OPDS 导航项带 feed，点开压入 trail 下钻，「上级」出栈。

布局（同 Library.build）：
  +-----------------------------------------------+
  | [←上级] [🔍搜索] [清除]             共N       |
  | +----+ +----+ +----+ +----+                   |
  | |封面| |封面| |封面| |封面|                   |
  | |书名| |书名| |书名| |书名|                   |
  | +----+ +----+ +----+ +----+                   |
  | [<]              N / M                   [>]  |
  +-----------------------------------------------+

@module koplugin.book.ui.store
--]]

local Library = require("desktop.pages.library")
local BookStore = require("book.store")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

---@class BookStorePage
---@field desktop BookDesktop
---@field name "store"|"opds" 所在 Tab
---@field store_id "zlib"|"opds" 书城后端
---@field empty_text string 空结果占位文案
---@field trail { title: string, feed: string }[] 已下钻的导航项，栈顶即当前 feed
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

local MAX_RESULTS = 200

---@param opts table
---@return BookStorePage
function Store:new(opts)
    opts.page = 1
    opts.page_size = 12
    opts.total = 0
    opts.trail = {}
    return setmetatable(opts, self)
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
    self.trail = {}
    self.page = 1
    self.total = 0
end

Store.onCancel = Store.cancel
Store.deactivate = Store.cancel
Store.destroy = Store.cancel

---@param event string
---@param payload table|nil
function Store:onEvent(event, payload)
    if event == "source_changed" then
        self:reset()
        return
    end
    if event ~= "swipe" then return end
    if payload.direction == "west" then
        self:gotoPage(self.page + 1)
    elseif payload.direction == "east" then
        self:gotoPage(self.page - 1)
    end
end

--- 从已加载结果中切出当前 UI 页。
---@return table
function Store:pageBooks()
    local all = self.books
    local page_size = self.page_size
    local first = (self.page - 1) * page_size + 1
    local books = {}
    for i = first, math.min(#all, first + page_size - 1) do
        books[#books + 1] = all[i]
    end
    return books
end

--- 复用图书馆网格构建书城页。
---@param ctx table
---@param state table
---@param opts table
---@return table
function Store:build(ctx, state, opts)
    opts.empty_text = self.empty_text
    opts.search_only = true
    opts.show_status = false
    opts.on_open = function(item)
        if item.feed then
            self.search = nil
            self:browse(function(trail) trail[#trail + 1] = { title = item.title, feed = item.feed } end)
        else
            require("desktop.detail").open(self.desktop, "store", item)
        end
    end
    opts.on_back = #self.trail > 0 and function()
        self:browse(function(trail) trail[#trail] = nil end)
    end or nil
    opts.on_search = function()
        self:showSearch()
    end
    return ctx.desktop.library:build(ctx, state, opts)
end

--- 丢弃已加载结果回第一页并重建；change 在清空后改写 trail。
---@param change fun(trail: table[])|nil
function Store:browse(change)
    self:cancel()
    if change then change(self.trail) end
    self.page = 1
    self.total = 0
    self.books = nil
    self.state = nil
    self.desktop:updateView()
end

--- 应用搜索；与图书馆筛选状态分开保存。搜索面向整个目录，回到目录根；空查询即退出搜索。
---@param query string|nil
function Store:applySearch(query)
    self.search = query and query ~= "" and query or nil
    self.trail = {}
    self:browse()
end

--- 弹出搜索框。
function Store:showSearch()
    self.desktop.library:showSearch(function(query)
        self:applySearch(query)
    end, self.search)
end

--- 同步 page_size（与图书馆同网格公式；不碰图书馆实例）；容量变化时丢弃当前页切片。
---@return number
function Store:syncPageSize()
    local desktop = self.desktop
    local n = Library.gridMetrics(desktop.dimen.w, desktop:contentHeight()).page_size
    if self.page_size ~= n then
        self.page_size = n
        self.state = nil
        self.page = math.min(self.page, self:pages())
    end
    return n
end

--- 计算总页数。
---@return number
function Store:pages()
    return math.max(1, math.ceil(self.total / self.page_size))
end

--- 跳转到指定页并重建。
---@param page number
function Store:gotoPage(page)
    page = math.max(1, math.min(self:pages(), page))
    if page == self.page and self.state then
        return
    end
    self.page = page
    self.state = self.books and { books = self:pageBooks() } or nil
    self.desktop:updateView()
end

--- 异步拉取书城列表（当前 trail 栈顶 feed 或搜索结果）。
function Store:fetch()
    local desktop = self.desktop
    self:cancel()
    self:syncPageSize()
    local search = self.search or ""
    local top = self.trail[#self.trail]

    --- 写入错误状态；失败结果不缓存。
    ---@param err string
    local function fail(err)
        if desktop.closed or desktop.tab ~= self.name then return end
        self.books = nil
        self.total = 0
        self.state = { books = {}, err = err }
        self.desktop:updateView()
    end

    self.fetch_cancel = require("store." .. self.store_id):listStoreAsync({
        page = 1,
        page_size = MAX_RESULTS,
        search = search,
        feed = top and top.feed,
    }, function(res, err)
        if desktop.closed or desktop.tab ~= self.name
            or (self.search or "") ~= search
            or self.trail[#self.trail] ~= top then
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
        self.page = math.min(self.page, self:pages())
        self.state = { books = self:pageBooks() }
        self.desktop:updateView()
    end)
end

--- 书城 widget。
---@return table
function Store:updateView()
    local desktop = self.desktop
    self:syncPageSize()
    local state = self.state
    if not state and self.books then
        state = { books = self:pageBooks() }
        self.state = state
    end
    if not state then
        UIManager:nextTick(require("ui.guard").wrap("store fetch", function()
            if desktop.closed or desktop.tab ~= self.name then return end
            self:fetch()
        end))
    end
    return self:build(desktop:ctx(), state or {}, {
        page = self.page,
        pages = self:pages(),
        total = self.total,
        on_prev = function()
            self:gotoPage(self.page - 1)
        end,
        on_next = function()
            self:gotoPage(self.page + 1)
        end,
    })
end

return Store
