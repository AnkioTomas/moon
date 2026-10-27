--[[--
书城 Tab：Z-Library / OPDS 与各启用书源的搜索。默认不加载任何书，只有搜索按钮；
工具条左侧的下拉切换搜索来源（见 Store.providers）。
Z-Library / OPDS 是书城后端（`store.<id>` 提供 listStoreAsync / installAsync，下载后导入本地书库）；
书源是带 `searchAsync` 的启用源，结果进详情页后加入本地书库（脏行，由源同步上行）。
OPDS 导航项带 feed，点开压入 trail 下钻，「上级」出栈。

布局（同 Library.build）：
  +-----------------------------------------------+
  | [来源▾] [←上级] [🔍搜索]            共N       |
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
local StoreCache = require("source.store_cache")
local MoonSettings = require("utils.settings")
local UIManager = require("ui/uimanager")
local Input = require("ui.input")
local _ = require("gettext")

---@class BookStorePage
---@field desktop BookDesktop
---@field name "store" 所在 Tab
---@field provider_id string|nil 当前搜索来源 id（zlib / opds / 书源 id）；nil = 取第一个可用来源
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
-- 浏览（榜单 / 分类）每次只取这么多：源按页顺序拉，墨水屏上多拉一页就多等一轮网络。
local BROWSE_RESULTS = 60

---@class StoreProvider
---@field id string
---@field name string
---@field store boolean|nil 是书城后端（store.<id>）；否则是书源
---@field source BookSource|nil
---@field backend table 当前来源的实现（书城后端模块或书源），可选带 browseAsync

--- 可搜索来源：已启用的 Z-Library / OPDS，再接已启用且带 searchAsync 的书源。
---@return StoreProvider[]
function Store.providers()
    local settings = MoonSettings.get("store")
    local list = {}
    if not settings.enabled then return list end
    if settings.zlib_enabled then list[#list + 1] = { id = "zlib", name = _("Z站"), store = true, backend = require("store.zlib") } end
    if settings.opds_enabled then list[#list + 1] = { id = "opds", name = _("OPDS"), store = true, backend = require("store.opds") } end
    local Registry = require("source.registry")
    for _idx, meta in ipairs(Registry.listEnabled()) do
        local source = Registry.resolve(meta.id)
        if source and source.searchAsync then
            list[#list + 1] = { id = meta.id, name = meta.name, source = source, backend = source }
        end
    end
    return list
end

--- 当前来源；记住的 id 不在可用列表里（被禁用）就退回第一个。
---@return StoreProvider|nil
function Store:provider()
    local list = Store.providers()
    for _idx, p in ipairs(list) do
        if p.id == self.provider_id then return p end
    end
    return list[1]
end

--- 当前来源能浏览（带 browseAsync 的书源）：没搜索词时展示它的 chip 分组 + 书列表。
---@return StoreProvider|nil
function Store:browsable()
    local provider = self:provider()
    return provider and provider.backend and provider.backend.browseAsync and provider or nil
end

--- 工具条下要画的 chip 分组；搜索中不显示。
---@return table[]
function Store:chipGroups()
    return not self.search and self.groups or {}
end

---@param opts table
---@return BookStorePage
function Store:new(opts)
    opts.provider_id = MoonSettings.get("store").provider
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
    self.node, self.groups = nil, nil
    self.trail = {}
    self.page = 1
    self.total = 0
end

--- 切回书城 / 桌面唤醒：丢弃已加载结果重问数据层；新鲜度由 source.store_cache 的 TTL 管，命中直接回。
---@param _changed boolean|nil 桌面切页签时是否为换页；本页不分这两种情况
function Store:activate(_changed)
    self.state = nil
    self.books = nil
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
    opts.empty_text = self.search and _("没有找到相关书籍") or _("点击搜索按钮查找书籍")
    opts.groups = self:chipGroups()
    opts.on_chip = function(id)
        self.node = id
        self:browse()
    end
    local current = self:provider()
    opts.provider = current and {
        text = current.name,
        on_pick = function(anchor) self:pickProvider(anchor) end,
    } or nil
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

--- 来源下拉；换来源保留搜索词，对新来源重搜。
---@param anchor table 按钮矩形
function Store:pickProvider(anchor)
    local current = self:provider()
    local items = {}
    for i, p in ipairs(Store.providers()) do
        items[i] = {
            text = p.name,
            checked = current and p.id == current.id,
            callback = function()
                self.provider_id = p.id
                local settings = MoonSettings.get("store")
                settings.provider = p.id
                MoonSettings.save("store")
                self.trail, self.node, self.groups = {}, nil, nil
                self:browse()
            end,
        }
    end
    require("ui.themes.widgets.list"):new{
        centered = true,
        anchor = anchor,
        inner_width = require("ui.themes").px(160),
        items = items,
    }:show()
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
    self.trail, self.node = {}, nil
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
    local head_h = Library.chipHeight(desktop.dimen.w, self:chipGroups())
    local n = Library.gridMetrics(desktop.dimen.w, desktop:contentHeight(), head_h).page_size
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
    page = Input.page(page, self:pages())
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

    local provider = self:provider()
    if not provider then return end
    local browsing = search == "" and self:browsable() ~= nil
    local function onResult(res, err)
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
        if browsing then self.groups = res.groups end
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
    end
    if browsing then
        self.fetch_cancel = StoreCache.browse(provider.backend, { node = self.node, limit = BROWSE_RESULTS }, onResult)
    elseif provider.store then
        self.fetch_cancel = require("store." .. provider.id):listStoreAsync({
            page = 1,
            page_size = MAX_RESULTS,
            search = search,
            feed = top and top.feed,
        }, onResult)
    else
        self.fetch_cancel = StoreCache.search(provider.source, search, onResult)
    end
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
    -- 默认不加载：没搜索词也没下钻就只给空页。
    if not state and not self.search and #self.trail == 0 and not self:browsable() then
        state = { books = {} }
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
        on_page = function(page) self:gotoPage(page) end,
    })
end

return Store
