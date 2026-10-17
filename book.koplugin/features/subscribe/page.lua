--[[--
桌面「订阅」页：订阅列表（按分组）→ 点开一个源看条目（新到旧，每页最多 20）→ 点条目打开文章。

  +-----------------------------------------------+
  | [⟳]            订阅                     [+]   |   ⟳ 刷新全部，+ 添加（RSS / 网站 / 公众号）
  | 科技                                          |
  | [rss] 少数派                         12  >    |   右侧是未读数
  | 未分组                                        |
  | [mp]  某公众号                        3  >    |
  +-----------------------------------------------+
  | [<]            少数派                   [⋯]   |   ⋯ 刷新 / 全部已读 / 重命名 / 分组 / 删除
  | ● 标题一                                      |
  |   2026-10-16 12:00                            |
  | [加载更早的文章]                              |   公众号翻到最后一页时
  | [<]              1 / 3                   [>]  |
  +-----------------------------------------------+

点开一个超过一小时没刷的源时只把它交给后台刷新任务（features.subscribe.refresh，插队首）；激活页签不扫全部，
刷新全部只走标题栏 ⟳；
刷新不归页面所有，切走页签、看书时照跑，页面只订阅进度来更新副标题、刷完重画。

@module koplugin.book.features.subscribe.page
--]]

local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Subscribe = require("features.subscribe")
local SubDB = require("features.subscribe.db")
local Refresh = require("features.subscribe.refresh")
local Theme = require("ui.themes")
local Box = require("ui.themes.widgets.box")
local Pager = require("ui.themes.widgets.pager")
local Row = require("ui.themes.widgets.row")
local Sections = require("ui.themes.widgets.sections")
local TitleBar = require("ui.themes.widgets.titlebar")
local T = require("ffi/util").template
local _ = require("gettext")

local PAGE_MAX = 20

---@class BookSubscribePage
---@field desktop BookDesktop
---@field name string
---@field feed_id integer|nil 正在看的源；nil = 订阅列表
---@field page integer
---@field busy string|nil 正在做的事（标题栏副标题）
---@field job table|nil
local Page = {}

--- 条目筛选（本次运行内记住，所有源共用）：all / unread / read。
local FILTERS = {
    all = { label = "全部" },
    unread = { label = "未读", read = false, tag = "仅未读" },
    read = { label = "已读", read = true, tag = "仅已读" },
}
Page.__index = Page

function Page:new(opts)
    opts.page = 1
    local page = setmetatable(opts, self)
    -- 只订一份：页面重建时先退掉旧的监听。
    if Page._unwatch then Page._unwatch() end
    Page._unwatch = Refresh.watch(function() page:redraw() end)
    return page
end

local function toast(text)
    require("ui.themes.widgets.toast"):new{ text = tostring(text), timeout = 3 }:show()
end

function Page:cancel()
    if self.job and self.job.cancel then self.job:cancel() end
    self.job, self.busy = nil, nil
end
Page.deactivate = Page.cancel
Page.destroy = Page.cancel
Page.onCancel = Page.cancel

function Page:redraw()
    local desktop = self.desktop
    if desktop and not desktop.closed and desktop.tab == self.name then desktop:updateView() end
end

--- 交给后台刷新任务；follow 时弹前台进度窗（手动刷新）。
---@param feeds table[]
---@param more boolean|nil
---@param follow boolean|nil
function Page:refresh(feeds, more, follow)
    Refresh.start(feeds, { more = more, follow = follow })
end

--- 标题栏副标题：页面自己的事优先，其次后台刷新进度。
---@return string|nil
function Page:status()
    return self.busy or Refresh.status()
end

--- 激活页签不自动刷新（不扫全部过期源）。
function Page:activate() end

function Page:onEvent(event, payload)
    if event ~= "swipe" or not self.feed_id then return end
    if payload.direction == "west" then
        self:gotoPage(self.page + 1)
    elseif payload.direction == "east" then
        self:gotoPage(self.page - 1)
    end
end

function Page:gotoPage(page)
    if page < 1 or page > (self.pages or 1) then return end
    self.page = page
    self:redraw()
end

---@param feed_id integer|nil
function Page:openFeed(feed_id)
    self.feed_id, self.page = feed_id, 1
    self:redraw()
    -- 只刷这一个源（过期才刷）；刷新全部只走订阅列表标题栏。
    local feed = feed_id and SubDB.feed(feed_id)
    if feed and os.time() - (feed.updated_at or 0) > Subscribe.STALE then
        UIManager:nextTick(function() self:refresh({ feed }) end)
    end
end

--- 添加：先试拉一次拿标题，再入库并刷新。
function Page:addUrl(kind)
    local Input = require("ui.themes.widgets.input")
    local fields = { { label = _("地址"), hint = "https://", input_type = "text" } }
    if kind == "site" then
        fields[#fields + 1] = { label = _("链接包含（可选）"), hint = _("只收地址里含这段文字的链接，如 /article/") }
    end
    fields[#fields + 1] = { label = _("分组（可选）"), hint = _("留空为未分组") }
    Input:new{
        title = kind == "rss" and _("添加 RSS") or _("添加网站"),
        fields = fields,
        callback = function(url, a, b)
            local filter, grp = kind == "site" and a or nil, kind == "site" and b or a
            if not url or url:match("^%s*$") then return end
            self.busy = _("正在解析…")
            self:redraw()
            Subscribe.probe(kind, url, filter, function(feed, err)
                self.busy = nil
                if not feed then
                    toast(err or _("加载失败"))
                    return self:redraw()
                end
                feed.grp = grp or ""
                self:insert(feed)
            end)
        end,
    }:show()
end

--- 入库；重复的提示一下。
function Page:insert(feed)
    if feed.kind == "mp" then Subscribe.allowMp(feed.url) end
    local id = SubDB.add(feed)
    if not id then
        toast(_("已经订阅过了"))
        return self:redraw()
    end
    self:refresh({ SubDB.feed(id) })
end

--- 公众号：读微信读书书架里的公众号，带书架分组。
function Page:addMp()
    self.busy = _("正在读取微信读书书架…")
    self:redraw()
    self.job = require("source.wechat.client"):shelfSyncAsync(function(data, err)
        self.busy, self.job = nil, nil
        self:redraw()
        if not data then return toast(err or _("请先登录微信读书")) end
        local accounts = require("source.wechat.mp").accounts(data)
        if #accounts == 0 then return toast(_("微信读书书架里没有公众号")) end
        local have = {}
        for _idx, feed in ipairs(SubDB.feeds()) do
            if feed.kind == "mp" then have[feed.url] = true end
        end
        local function feedOf(a) return { kind = "mp", url = a.id, title = a.title, grp = a.group } end
        local fresh = {}
        for _idx, a in ipairs(accounts) do
            if not have[a.id] then fresh[#fresh + 1] = a end
        end
        local items = {}
        if #fresh > 1 then
            items[1] = { text = T(_("全部导入（%1）"), #fresh), variant = "primary", callback = function()
                local added = {}
                for _idx, a in ipairs(fresh) do
                    Subscribe.allowMp(a.id)
                    local id = SubDB.add(feedOf(a))
                    if id then added[#added + 1] = SubDB.feed(id) end
                end
                self:refresh(added)
            end }
            items[2] = { separator = true }
        end
        for _idx, a in ipairs(accounts) do
            items[#items + 1] = {
                text = a.group ~= "" and (a.title .. " · " .. a.group) or a.title,
                enabled = not have[a.id],
                callback = function() self:insert(feedOf(a)) end,
            }
        end
        require("ui.themes.widgets.sheet"):new{ title = _("添加公众号"), items = items }:show()
    end)
end

function Page:showAdd()
    require("ui.themes.widgets.sheet"):new{ title = _("添加订阅"), items = {
        { text = _("RSS / Atom"), callback = function() self:addUrl("rss") end },
        { text = _("任意网站"), callback = function() self:addUrl("site") end },
        { text = _("微信读书公众号"), callback = function() self:addMp() end },
    } }:show()
end

--- 一个源的管理菜单。
function Page:showManage(feed)
    local Input = require("ui.themes.widgets.input")
    local function edit(title, key)
        Input:new{ title = title, fields = { { text = feed[key] } }, callback = function(value)
            if key == "title" and (not value or value:match("^%s*$")) then return end
            SubDB.update(feed.id, { [key] = value or "" })
            self:redraw()
        end }:show()
    end
    require("ui.themes.widgets.sheet"):new{ title = feed.title, items = {
        { text = _("刷新"), callback = function() self:refresh({ feed }, false, true) end },
        { text = T(_("筛选：%1"), _(FILTERS[Page.filter or "all"].label)), callback = function() self:showFilter() end },
        { text = _("全部标为已读"), callback = function()
            SubDB.markRead(feed.id)
            self:redraw()
        end },
        { text = _("重命名"), callback = function() edit(_("重命名"), "title") end },
        { text = _("修改分组"), callback = function() edit(_("修改分组"), "grp") end },
        { separator = true },
        { text = _("取消订阅"), callback = function()
            require("ui.themes.widgets.confirm"):new{
                text = T(_("取消订阅「%1」？已缓存的文章一并删除。"), feed.title),
                ok_text = _("取消订阅"),
                ok_callback = function()
                    Subscribe.remove(feed)
                    self:openFeed(nil)
                end,
            }:show()
        end },
    } }:show()
end

--- 打开文章：订阅按一本按章书交给月读阅读（features.subscribe.source），章号 = 文章在目录（同本页顺序）里的位置。
function Page:openItem(feed, item)
    local idx
    for i, row in ipairs(SubDB.items(feed.id, 1, -1)) do
        if row.guid == item.guid then idx = i break end
    end
    if not idx then return end
    require("desktop.open").book(self.desktop.plugin, require("features.subscribe.source").book(feed), nil,
        { chapter_idx = idx })
end

--- 订阅列表分节：分组 → 源。
function Page:feedSections()
    local sections, by = {}, {}
    for _idx, feed in ipairs(SubDB.feeds()) do
        local key = feed.grp ~= "" and feed.grp or _("未分组")
        if not by[key] then
            by[key] = { title = key, rows = {} }
            sections[#sections + 1] = by[key]
        end
        local provider = Subscribe.providers[feed.kind]
        table.insert(by[key].rows, function(iw)
            return Row.widget({
                width = iw, icon = provider and provider.icon, title = feed.title,
                subtitle = provider and provider.label,
                status = feed.unread > 0 and tostring(feed.unread) or nil, status_on = feed.unread > 0,
                callback = function() self:openFeed(feed.id) end,
            })
        end)
    end
    if #sections == 0 then
        sections[1] = { title = _("订阅"), rows = { function(iw)
            return Row.widget({ width = iw, icon = "add", title = _("还没有订阅"),
                subtitle = _("点右上角添加 RSS、网站或公众号"), callback = function() self:showAdd() end })
        end } }
    end
    return sections
end

---@param w integer
---@param h integer
---@return table
function Page:feedsView(w, h)
    local bar = TitleBar.widget({
        width = w, title = _("订阅"), subtitle = self:status(),
        left_icon = "refresh", left_callback = function() self:refresh(SubDB.feeds(), false, true) end,
        right_icon = "add", right_callback = function() self:showAdd() end,
    })
    local body_h = h - bar:getSize().h
    local body, page = Sections.widget({
        width = w, height = body_h, page = self.page, sections = self:feedSections(),
        on_page = function(p) self.page = p; self:redraw() end,
    })
    self.page = page
    return VerticalGroup:new{ align = "left", bar, body }
end

function Page:showFilter()
    local items = {}
    for _i, key in ipairs({ "all", "unread", "read" }) do
        items[#items + 1] = { text = _(FILTERS[key].label), variant = (Page.filter or "all") == key and "primary" or nil, callback = function()
            Page.filter = key ~= "all" and key or nil
            self.page = 1
            self:redraw()
        end }
    end
    require("ui.themes.widgets.sheet"):new{ title = _("筛选"), items = items }:show()
end

---@param feed table
---@param w integer
---@param h integer
---@return table
function Page:itemsView(feed, w, h)
    local t = Theme.current()
    local subtitle = self:status() or (feed.unread > 0 and T(_("%1 篇未读"), feed.unread) or nil)
    local tag = FILTERS[Page.filter or "all"].tag
    if tag and not self:status() then subtitle = subtitle and (subtitle .. " · " .. _(tag)) or _(tag) end
    local bar = TitleBar.widget({
        width = w, title = feed.title,
        subtitle = subtitle,
        left_icon = "arrow_back", left_callback = function() self:openFeed(nil) end,
        right_icon = "more_horiz", right_callback = function() self:showManage(feed) end,
    })
    local pager_h = Theme.px(t.control.height)
    local avail = h - bar:getSize().h - pager_h
    local probe = Row.widget({ width = w, title = "M", subtitle = "M" })
    local row_h = probe:getSize().h
    probe:free()
    -- 公众号还有更早的文章时留一行给「加载更早的文章」。
    local more = (feed.cursor or 0) > 0
    local size = math.max(1, math.min(PAGE_MAX, math.floor(avail / row_h) - (more and 1 or 0)))
    local read = FILTERS[Page.filter or "all"].read
    local _first, total = SubDB.items(feed.id, 1, 0, read)
    self.pages = math.max(1, math.ceil(total / size))
    self.page = math.max(1, math.min(self.page, self.pages))
    local items = SubDB.items(feed.id, self.page, size, read)
    local list = VerticalGroup:new{ align = "left" }
    for _idx, item in ipairs(items) do
        list[#list + 1] = Row.widget({
            width = w, title = (item.read and "" or "● ") .. item.title,
            subtitle = item.time > 0 and os.date("%Y-%m-%d %H:%M", item.time) or nil,
            selected = false,
            callback = function() self:openItem(feed, item) end,
        })
    end
    if more and self.page == self.pages then
        list[#list + 1] = Row.widget({ width = w, icon = "refresh", title = _("加载更早的文章"),
            callback = function() self:refresh({ feed }, true) end })
    end
    if #items == 0 then
        list[1] = Row.widget({ width = w, title = self:status() or _("暂无文章"), enabled = false })
    end
    local group = VerticalGroup:new{ align = "left", bar, list,
        VerticalSpan:new{ width = math.max(0, avail - list:getSize().h) } }
    group[#group + 1] = Pager.widget({
        width = w, page = self.page, pages = self.pages,
        on_prev = function() self:gotoPage(self.page - 1) end,
        on_next = function() self:gotoPage(self.page + 1) end,
    })
    return group
end

---@return table
function Page:updateView()
    local desktop = self.desktop
    local w, h = desktop.dimen.w, desktop:contentHeight()
    local feed = self.feed_id and SubDB.feed(self.feed_id)
    if not feed then self.feed_id = nil end
    local view = feed and self:itemsView(feed, w, h) or self:feedsView(w, h)
    return Box:new{ style = { bg = Theme.current().color.page }, width = w, height = h, view }
end

return Page
