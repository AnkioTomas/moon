--[[--
桌面「订阅」页：跨订阅源的文章流（纸质风格，paper.lua），点条目打开文章。

  +-----------------------------------------------+
  | [全部 ⌄]                      [+] [⟳] [↓] [🗑] |   左：范围选择（全部 / 分组 / 单个源，书城同款下拉）；
  | 未读文章                                  940 |   右：添加、刷新、缓存未读、订阅源管理
  | 分组 │ 未读 全部 收藏 │ 搜索                   |
  | • 标题                                        |
  |   来源 · 分组 · 日期                          |
  | [<]              第 1 / 20 页             [>] |
  +-----------------------------------------------+

范围（源 / 分组）+ 未读·全部·收藏 + 搜索词就是文章流的筛选条件，也是阅读器目录的范围（features.subscribe.source）。
刷新不归页面所有，切走页签、看书时照跑，页面只订阅进度来更新副标题、刷完重画。

@module koplugin.book.features.subscribe.page
--]]

local UIManager = require("ui/uimanager")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local Subscribe = require("features.subscribe")
local SubDB = require("features.subscribe.db")
local Refresh = require("features.subscribe.refresh")
local Theme = require("ui.themes")
local Box = require("ui.themes.widgets.box")
local Button = require("ui.themes.widgets.button")
local T = require("ffi/util").template
local _ = require("gettext")

---@class BookSubscribePage
---@field pages integer|nil 总页数
---@field desktop BookDesktop
---@field name string
---@field page integer
---@field busy string|nil 正在做的事（标题栏副标题）
---@field job table|nil
local Page = {}

--- 筛选条件（落盘 features.subscribe 的 filter，重启后保留）：范围 = 单个源 feed_filter 或分组 group_filter（nil 全部，"" 未分组），页签 unread / all / star，搜索词。
Page.feed_filter = nil
Page.group_filter = nil
Page.stream_mode = "unread"
Page.stream_q = ""

--- 从设置恢复筛选；记着的订阅源已被删就回到全部。
local function restore()
    local saved = require("utils.settings").get("features.subscribe").filter
    if not saved then return end
    Page.group_filter, Page.stream_mode, Page.stream_q = saved.grp, saved.mode or "unread", saved.q or ""
    Page.feed_filter = saved.feed and SubDB.feed(saved.feed) and saved.feed or nil
end

local function persist()
    local MoonSettings = require("utils.settings")
    MoonSettings.get("features.subscribe").filter = {
        feed = Page.feed_filter, grp = Page.group_filter, mode = Page.stream_mode, q = Page.stream_q }
    MoonSettings.save("features.subscribe")
end

Page.__index = Page

function Page:new(opts)
    opts.page = 1
    restore()
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
    if event ~= "swipe" then return end
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

--- 添加：先试拉一次拿标题，再入库并刷新。
function Page:addUrl(kind)
    local Input = require("ui.themes.widgets.input")
    local fields = { { label = _("地址"), hint = "https://", input_type = "text" } }
    if kind == "site" then
        fields[#fields + 1] = { label = _("链接包含（可选）"), hint = _("只收地址里含这段文字的链接，如 /article/") }
    end
    fields[#fields + 1] = { label = _("分组（可选）"), hint = _("留空为未分组") }
    Input:new{
        title = kind == "rss" and _("添加 RSS") or kind == "page" and _("添加网页") or _("添加网站"),
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

local RECOMMENDED = {
    { title = "摸鱼日报", url = "https://api.ankio.net/myrl/rss" },
    { title = "今日要闻", url = "https://api.ankio.net/paper/rss" },
}

--- 推荐源：标题已知，直接入库；已订阅的置灰。
function Page:addRecommended()
    local have = {}
    for _idx, feed in ipairs(SubDB.feeds()) do
        if feed.kind == "rss" then have[feed.url] = true end
    end
    local items = {}
    for _idx, rec in ipairs(RECOMMENDED) do
        items[#items + 1] = {
            text = rec.title,
            enabled = not have[rec.url],
            callback = function()
                self:insert({ kind = "rss", url = rec.url, title = rec.title })
            end,
        }
    end
    require("ui.themes.widgets.sheet"):new{ title = _("推荐"), items = items }:show()
end

function Page:showAdd()
    require("ui.themes.widgets.sheet"):new{ title = _("添加订阅"), items = {
        { text = _("RSS / Atom"), callback = function() self:addUrl("rss") end },
        { text = _("网站文章链接"), callback = function() self:addUrl("site") end },
        { text = _("网页本身"), callback = function() self:addUrl("page") end },
        { text = _("微信读书公众号"), callback = function() self:addMp() end },
        { text = _("推荐"), callback = function() self:addRecommended() end },
    } }:show()
end


--- 当前筛选条件（SubDB.stream / SubDB.scope 的参数）。
---@return table
function Page:spec()
    local feed = Page.feed_filter
    return { feed = feed, grp = not feed and Page.group_filter or nil, mode = Page.stream_mode, q = Page.stream_q }
end

--- 范围名：全部 / 分组名 / 源名。
---@return string
function Page:scopeLabel()
    local feed = Page.feed_filter and SubDB.feed(Page.feed_filter)
    if feed then return feed.title end
    local grp = Page.group_filter
    if grp == nil then return _("全部") end
    return grp == "" and _("未分组") or grp
end

--- 改筛选条件并回到第一页重画。
---@param fields table feed_filter / group_filter / stream_mode / stream_q；false 表示清掉（nil 在 pairs 里留不住）
function Page:filter(fields)
    for key, value in pairs(fields) do
        if value == false then value = nil end
        Page[key] = value
    end
    persist()
    self.page = 1
    self:redraw()
end

--- 范围下拉（同书城来源下拉）：全部 / 各分组 / 各订阅源。
---@param anchor table 按钮矩形
function Page:pickScope(anchor)
    local feeds = SubDB.feeds()
    local items = {}
    local function add(text, icon, checked, fields, unread)
        items[#items + 1] = { text = text, icon = icon, checked = checked, mandatory = unread and unread > 0 and tostring(unread) or nil,
            callback = function() self:filter(fields) end }
    end
    local none = Page.feed_filter == nil and Page.group_filter == nil
    local all_unread = 0
    for _idx, feed in ipairs(feeds) do all_unread = all_unread + feed.unread end
    add(_("全部"), "select_all", none, { feed_filter = false, group_filter = false }, all_unread)
    local seen, names, ungrouped = {}, {}, false
    for _idx, feed in ipairs(feeds) do
        local g = feed.grp or ""
        if g == "" then ungrouped = true
        elseif not seen[g] then seen[g] = true; names[#names + 1] = g end
    end
    table.sort(names)
    for _idx, g in ipairs(names) do
        local unread = 0
        for _i, feed in ipairs(feeds) do
            if feed.grp == g then unread = unread + feed.unread end
        end
        add(g, "folder", Page.feed_filter == nil and Page.group_filter == g, { feed_filter = false, group_filter = g }, unread)
    end
    if ungrouped and #names > 0 then
        add(_("未分组"), "folder_off", Page.feed_filter == nil and Page.group_filter == "", { feed_filter = false, group_filter = "" })
    end
    for _idx, feed in ipairs(feeds) do
        local provider = Subscribe.providers[feed.kind]
        add(feed.title, provider and provider.icon or "rss_feed", Page.feed_filter == feed.id,
            { feed_filter = feed.id, group_filter = false }, feed.unread)
    end
    require("ui.themes.widgets.list"):new{
        centered = true, anchor = anchor, inner_width = Theme.px(260), items = items,
    }:show()
end

--- 当前范围内的订阅源（刷新用）。
---@return table[]
function Page:scopeFeeds()
    local out = {}
    for _idx, feed in ipairs(SubDB.feeds()) do
        if Page.feed_filter and feed.id == Page.feed_filter
            or not Page.feed_filter and (Page.group_filter == nil or (feed.grp or "") == Page.group_filter) then
            out[#out + 1] = feed
        end
    end
    return out
end

--- 当前范围（来源 / 分组）的全部文章标已读，确认后执行。
function Page:markAllRead()
    local Toast = require("ui.themes.widgets.toast")
    local feeds = self:scopeFeeds()
    local unread = 0
    for _idx, feed in ipairs(feeds) do unread = unread + feed.unread end
    if unread == 0 then return Toast:new{ text = _("没有未读文章"), timeout = 3 }:show() end
    require("ui.themes.widgets.confirm"):new{
        text = T(_("将「%1」的 %2 篇未读文章全部标为已读？"), self:scopeLabel(), unread),
        ok_text = _("全部已读"),
        ok_callback = function()
            for _idx, feed in ipairs(feeds) do SubDB.markRead(feed.id) end
            self:redraw()
        end,
    }:show()
end

--- 当前范围的全部未读文章正文进后台缓存任务（kind = cache）；离线时有网才能下，直接提示。
function Page:cacheUnread()
    local Toast = require("ui.themes.widgets.toast")
    local spec = self:spec()
    spec.mode = "unread"
    local items = SubDB.stream(spec, 1, -1)
    if #items == 0 then return Toast:new{ text = _("没有未读文章"), timeout = 3 }:show() end
    if not require("ui/network/manager"):isConnected() then
        return Toast:new{ text = _("网络不可用，请先连接 Wi-Fi"), timeout = 3 }:show()
    end
    require("workers.ui.task_dialog").start{
        key = "cache\0subscribe\0" .. SubDB.scope(spec),
        kind = "cache",
        title = self:scopeLabel(),
        restartable = true,
        run = function(report, done)
            return Subscribe.cacheUnread(items, report, function(cached, total, failed, err)
                done({ ok = failed == 0, cached = cached, total = total, err = err })
            end)
        end,
        on_done = function(result)
            Toast:new{
                text = result.ok and T(_("已缓存 %1 篇未读文章"), result.cached)
                    or T(_("缓存完成 %1/%2 篇，其余失败：%3"), result.cached, result.total, tostring(result.err)),
                timeout = 3,
            }:show()
        end,
    }
end

--- 编辑一个源：重命名 / 修改分组。
---@param feed table
---@param after fun() 改完回调
function Page:editFeed(feed, after)
    local Input = require("ui.themes.widgets.input")
    local function edit(title, key)
        Input:new{ title = title, fields = { { text = feed[key] } }, callback = function(value)
            if key == "title" and (not value or value:match("^%s*$")) then return end
            SubDB.update(feed.id, { [key] = value or "" })
            self:redraw()
            after()
        end }:show()
    end
    require("ui.themes.widgets.sheet"):new{ title = feed.title, items = {
        { text = _("重命名"), callback = function() edit(_("重命名"), "title") end },
        { text = _("修改分组"), callback = function() edit(_("修改分组"), "grp") end },
    } }:show()
end

--- 订阅源管理：每行右侧是编辑、删除（取消订阅）。
function Page:showManage()
    local list
    local function items()
        local out = {}
        for _idx, feed in ipairs(SubDB.feeds()) do
            local provider = Subscribe.providers[feed.kind]
            out[#out + 1] = {
                text = feed.title, icon = provider and provider.icon or "rss_feed", keep_open = true,
                widget = function()
                    return HorizontalGroup:new{ align = "center",
                        Button:new{ icon = "edit", variant = "ghost", size = "small", callback = function()
                            self:editFeed(feed, function() list:setItems(items()) end)
                        end },
                        HorizontalSpan:new{ width = Theme.px(Theme.current().space.xs) },
                        Button:new{ icon = "delete", variant = "ghost", size = "small", callback = function()
                            require("ui.themes.widgets.confirm"):new{
                                text = T(_("取消订阅「%1」？已缓存的文章一并删除。"), feed.title),
                                ok_text = _("取消订阅"),
                                ok_callback = function()
                                    Subscribe.remove(feed)
                                    if Page.feed_filter == feed.id then self:filter({ feed_filter = false }) end
                                    list:setItems(items())
                                    self:redraw()
                                end,
                            }:show()
                        end } }
                end,
            }
        end
        if #out == 0 then out[1] = { text = _("还没有订阅"), enabled = false } end
        return out
    end
    list = require("ui.themes.widgets.list"):new{ title = _("订阅源管理"), items = items() }
    list:show()
end

--- 打开文章：阅读器的书是当前筛选范围（目录 = 此刻的文章流），章号 = 文章在目录里的位置。
---@param item table SubDB.stream 的一行
function Page:openItem(item)
    local Source = require("features.subscribe.source")
    local id = SubDB.scope(self:spec())
    local uid = id:match("^%d+$") and item.guid or (item.feed_id .. ":" .. item.guid)
    for _idx, chapter in ipairs(Source.toc({ stable_id = id })) do
        if chapter.uid == uid then
            return require("desktop.open").book(self.desktop.plugin, Source.book(id, self:bookTitle()), nil,
                { chapter_idx = chapter.idx })
        end
    end
end

--- 阅读器里的书名：范围名，带上非默认的页签与搜索词。
---@return string
function Page:bookTitle()
    local title = self:scopeLabel()
    if Page.stream_mode == "unread" then title = title .. " · " .. _("未读")
    elseif Page.stream_mode == "star" then title = title .. " · " .. _("收藏") end
    if Page.stream_q ~= "" then title = title .. " · " .. Page.stream_q end
    return title
end

---@return table
function Page:updateView()
    local desktop = self.desktop
    local w, h = desktop.dimen.w, desktop:contentHeight()
    return Box:new{ style = { bg = Theme.current().color.page }, width = w, height = h,
        require("features.subscribe.paper").view(self, w, h) }
end

return Page
