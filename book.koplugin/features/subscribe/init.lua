--[[--
订阅：RSS / Atom、任意网页、微信读书公众号。桌面「订阅」页（features.subscribe.page）的数据层。

每种来源是一个 provider：
  fetch(feed, cursor, cb(items, next_cursor, err))  拉一页条目（新到旧）；next_cursor 为 nil 表示没有更早的了
  content(feed, item, images_dir, cb(html, err, meta))  文章正文片段；images_dir 非 nil 时图片落地；meta 可带 byline
只有公众号分页（maxIdx）；RSS / 网页一次拿全。
阅读走月读按章阅读：一个订阅是一本书、一篇文章是一章（features.subscribe.source），不记进度与统计。
总开关关着时桌面不显示「订阅」页，这里的函数不会被调用。

@module koplugin.book.features.subscribe
--]]

local Parse = require("features.subscribe.parse")
local SubDB = require("features.subscribe.db")
local Paths = require("utils.paths")
local Text = require("utils.text")
local logger = require("utils.log")
local _ = require("gettext")

local Subscribe = {}

--- 网页 / 订阅源超过这么大不解析：Readability 要建整棵树，3MB 页面去掉脚本后树也就几 MB，再大不碰。
local MAX_PAGE = 3 * 1024 * 1024
--- 单张图片上限。
local MAX_IMAGE = 2 * 1024 * 1024
--- RSS 自带正文去掉标签后超过这么多字节才当全文（约 500 个汉字）；否则当摘要、去抓原文。
local FULL_TEXT = 1500
--- 打开订阅页时，超过这么久没刷新的源自动刷新（秒）。
Subscribe.STALE = 3600

--- 网页里的私有 / 本机地址（含 .local、IPv4 私网与链路本地、IPv6 本机 / ULA / 链路本地、纯数字主机）。
--- 远程管理网页发起的抓取（试拉 / 添加 / 导入 / 批量）一律拒绝，免得局域网里的页面借设备探内网。
--- 只看字面量，域名解析到内网（DNS rebinding）拦不住；设备上自己添加的订阅不受限（可订阅局域网 RSSHub）。
---@param url string
---@return boolean
function Subscribe.privateHost(url)
    local host = tostring(url or ""):match("^%a[%w+.-]*://([^/?#]*)")
    if not host then return true end
    host = host:gsub("^.*@", ""):lower()
    if host:sub(1, 1) == "[" then host = host:match("^%[(.-)%]") or host else host = host:gsub(":%d*$", "") end
    host = host:gsub("%.$", "")
    if host == "" or host == "localhost" or host:match("%.localhost$") or host:match("%.local$")
        or host:match("%.internal$") or host:match("%.lan$") then
        return true
    end
    if host:find(":", 1, true) then
        return host == "::1" or host == "::" or host:match("^f[cd]") ~= nil or host:match("^fe[89ab]") ~= nil
            or host:match("^::ffff:") ~= nil
    end
    if host:match("^[%d.]+$") or host:match("^0x") then
        local a, b = host:match("^(%d+)%.(%d+)%.%d+%.%d+$")
        a, b = tonumber(a), tonumber(b)
        if not a then return true end -- 十进制 / 八进制 / 不全的 IPv4 简写
        return a == 0 or a == 10 or a == 127 or a >= 224 or (a == 169 and b == 254)
            or (a == 172 and b >= 16 and b <= 31) or (a == 192 and b == 168) or (a == 100 and b >= 64 and b <= 127)
    end
    return false
end

local ACCEPT = "application/rss+xml,application/atom+xml,application/xml,text/html,*/*"

--- 流式 GET：边收边数，超过 MAX_PAGE 立刻断开（不先整页下完再判断）。
--- opts.public：只许公网地址（每一跳都查）。
---@param url string
---@param cb fun(body: string|nil, err: any)
---@param opts { public: boolean|nil, hops: integer|nil }|nil
---@return table|nil
local function get(url, cb, opts)
    -- 跳转自己跟：turbo 只认 301/302，且把相对 Location（如 ghfast.top 回的 `/https://github.com/...`）
    -- 当成完整地址解析失败；GitHub release 的 latest 下载、各类镜像都是相对跳转。
    opts = opts or {}
    local hops = opts.hops or 0
    if opts.public and Subscribe.privateHost(url) then
        cb(nil, _("不允许访问局域网或本机地址"))
        return nil
    end
    local Request = require("http.request")
    local job = { cancelled = false }
    local inner
    local chunks, size, res, too_big = {}, 0, {}, false
    local function abort()
        too_big, chunks = true, {}
        if inner and inner.cancel then inner:cancel() end
    end
    inner = Request.stream({
        url = url,
        headers = require("http.request.header").forRequest(nil, ACCEPT),
        timeout = require("http.timeout").net(3),
    }, {
        on_headers = function(code, headers)
            res.code, res.headers = tonumber(code), headers
            local len = tonumber((Request.header(res, "Content-Length")))
            if len and len > MAX_PAGE and res.code and res.code < 300 then abort() end
        end,
        on_data = function(chunk)
            if too_big then return end
            size = size + #chunk
            if size > MAX_PAGE then return abort() end
            chunks[#chunks + 1] = chunk
        end,
        on_done = function(err)
            if job.cancelled then return end
            if too_big then return cb(nil, _("页面太大，无法解析")) end
            local code = res.code
            if code and code >= 300 and code < 400 and code ~= 304 then
                local loc = Request.header(res, "Location")
                if not loc or loc == "" or hops >= 5 then return cb(nil, err or _("跳转次数过多")) end
                local sub = get(Text.absoluteUrl(url, Text.trim(loc)), cb, { public = opts.public, hops = hops + 1 })
                inner = sub
                return
            end
            if err then return cb(nil, err) end
            local body = table.concat(chunks)
            chunks = nil
            local text, charset = require("utils.charset").toUtf8(body, Request.header(res, "Content-Type"))
            if not text then return cb(nil, string.format(_("不支持的网页编码：%s"), charset)) end
            cb(text)
        end,
    })
    function job:cancel()
        self.cancelled = true
        if inner and inner.cancel then inner:cancel() end
    end
    return job
end

--- 下载文本（跟随跳转、限大小）；OPML 地址导入用。public 为真只许公网地址。
Subscribe.fetchText = function(url, cb, public) return get(url, cb, { public = public }) end

--- 普通网页图片：Referer 用文章地址（不少图床认它）。图片地址来自第三方正文：文章本身来自公网时，跳转自己跟、每一跳都不许落到内网（局域网自建 RSSHub 的文章不限）。
---@param referer string
---@return fun(url: string, cb: fun(data: string|nil)): table|nil
local function imageDownloader(referer)
    local lan = Subscribe.privateHost(referer)
    return function(url, cb)
        local job = { cancelled = false }
        local function fetch(target, hops)
            if not lan and Subscribe.privateHost(target) then return cb(nil) end
            job.inner = require("http.request").request({
                url = target, method = "GET",
                headers = { ["Accept"] = "image/*", ["Referer"] = referer },
                timeout = require("http.timeout").net(3),
            }, function(res)
                if job.cancelled then return end
                local code = res and res.code
                if code and code >= 300 and code < 400 then
                    local loc = require("http.request").header(res, "Location")
                    if not loc or loc == "" or hops >= 5 then return cb(nil) end
                    return fetch(Text.absoluteUrl(target, Text.trim(loc)), hops + 1)
                end
                local body = code == 200 and res.body
                cb(body and body ~= "" and #body <= MAX_IMAGE and body or nil)
            end)
        end
        fetch(url, 0)
        function job:cancel()
            self.cancelled = true
            if self.inner and self.inner.cancel then self.inner:cancel() end
        end
        return job
    end
end

--- 网页正文：相对图片地址补全，再按需落地。
local function finishPage(html, link, images_dir, cb)
    html = Parse.cfEmail(html)
    html = html:gsub('(<img src=")([^"]+)', function(prefix, src)
        return prefix .. (Text.absoluteUrl(link, Text.xmlDecode(src)) or src)
    end)
    if not images_dir then return cb(html) end
    return require("source.assets").localizeAsync(html, images_dir, imageDownloader(link), cb)
end

--- Readability 要建整棵 DOM、几百 KB 的页面在 Kindle 上要跑好几秒：放进 fork 子进程（workers.job light），
--- 主线程不卡；子进程失败 / 超时退回主线程的轻量 Parse.article。回调 cb(html|nil, meta|nil)。
---@param body string
---@param link string
---@param cb fun(html: string|nil, meta: table|nil)
---@return table|nil job
function Subscribe.extract(body, link, cb)
    local function fallback() cb(Parse.article(body)) end
    return require("workers.job").run(function()
        local html, meta = require("features.subscribe.readability").extract(body, link)
        return { html = html, meta = meta }
    end, {
        name = "subscribe_readability",
        kind = "light",
        timeout = 60,
        on_done = function(r)
            if type(r) == "table" and type(r.html) == "string" then return cb(r.html, r.meta) end
            fallback()
        end,
        on_failed = function(err)
            logger.warn("subscribe readability failed", err)
            fallback()
        end,
    })
end

--- 抓原文页并抽正文（Readability，抽不出退回整页）；fallback 是抓取失败时用的 RSS 摘要。
--- cb 第三个参数是 Readability 元数据（署名等），抽不出时为 nil。
local function fetchArticle(link, images_dir, cb, fallback, public)
    local job, cancelled
    local function finish(html, meta, err)
        if cancelled then return end
        if not html and fallback then html = fallback end
        if not html then return cb(nil, err or _("正文解析失败")) end
        job = finishPage(html, link, images_dir, function(out) cb(out, nil, meta) end)
    end
    job = get(link, function(body, err)
        if not body then return finish(nil, nil, err) end
        job = Subscribe.extract(Parse.cfEmail(body), link, function(html, meta) finish(html, meta) end)
    end, { public = public })
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job:cancel() end
    end }
end

Subscribe.providers = {
    rss = {
        icon = "rss_feed",
        label = _("RSS"),
        fetch = function(feed, _cursor, cb)
            return get(feed.url, function(body, err)
                local parsed = body and Parse.feed(body)
                if not parsed then
                    cb(nil, nil, err or _("不是有效的 RSS / Atom 订阅源"))
                    return
                end
                cb(parsed.items, nil, nil, parsed.title)
            end, { public = feed.public })
        end,
        content = function(feed, item, images_dir, cb)
            -- 自带全文直接用；只有摘要（或很短）就抓原文跑 Readability，抓不到再用摘要。
            local summary = SubDB.summary(feed.id, item.guid)
            if summary and (#Text.stripHtml(summary) >= FULL_TEXT or item.link == "") then
                return finishPage(summary, item.link ~= "" and item.link or feed.url, images_dir, cb)
            end
            if item.link == "" then return cb(nil, _("条目没有正文")) end
            return fetchArticle(item.link, images_dir, cb, summary, feed.public)
        end,
    },
    site = {
        icon = "public",
        label = _("网站"),
        fetch = function(feed, _cursor, cb)
            return get(feed.url, function(body, err)
                if not body then return cb(nil, nil, err) end
                local items = Parse.links(body, feed.url, feed.filter)
                if #items == 0 then return cb(nil, nil, _("页面里没找到文章链接")) end
                cb(items, nil, nil, Parse.title(body))
            end, { public = feed.public })
        end,
        content = function(feed, item, images_dir, cb)
            return fetchArticle(item.link, images_dir, cb, nil, feed.public)
        end,
    },
    mp = {
        icon = "newspaper",
        label = _("公众号"),
        fetch = function(feed, cursor, cb)
            local Mp = require("source.wechat.mp")
            return Mp.fetchArticlesAsync(feed.url, cursor or 0, function(items, err)
                if not items then return cb(nil, nil, err) end
                local next_cursor = #items >= Mp.PAGE and (cursor or 0) + #items or nil
                cb(items, next_cursor)
            end)
        end,
        content = function(_feed, item, images_dir, cb)
            return require("source.wechat.mp").fetchContentAsync(item.guid, images_dir, cb)
        end,
    },
}

--- 配置（总开关、是否下载图片）。
---@return table
function Subscribe.settings()
    return require("utils.settings").get("features.subscribe")
end

--- 添加前试拉一次：确认能解析、拿到标题。RSS 地址给的是网页时按 <link rel="alternate"> 找订阅源。
--- public 为真（远程管理网页发起）只许公网地址。alternate 绕回已试过的地址（A→B→A）即停。
---@param kind "rss"|"site"
---@param url string
---@param filter string|nil
---@param cb fun(feed: table|nil, err: any)
---@param public boolean|nil
function Subscribe.probe(kind, url, filter, cb, public, seen)
    url = Text.trim(url or "")
    if not url:match("^https?://") then url = "https://" .. url end
    seen = seen or {}
    seen[url] = true
    local feed = { kind = kind, url = url, filter = filter or "", public = public or nil }
    Subscribe.providers[kind].fetch(feed, nil, function(items, _next, err, title)
        if items then
            feed.title = title ~= nil and title ~= "" and title or url
            feed.public = nil
            return cb(feed)
        end
        if kind ~= "rss" then return cb(nil, err) end
        get(url, function(body)
            local tag = body and body:match('<link[^>]-type=["\']application/[rs%a]+%+xml["\'][^>]*>')
            local href = tag and tag:match('href=["\']([^"\']+)')
            local alt = href and Text.absoluteUrl(url, Text.xmlDecode(href))
            if not alt or seen[alt] then return cb(nil, err) end
            Subscribe.probe("rss", alt, nil, cb, public, seen)
        end, { public = public })
    end)
end

--- 刷新一个源；more 为真时拉更早的一页（只有公众号有）。
---@param feed table SubDB 行
---@param more boolean|nil
---@param cb fun(added: integer|nil, err: any)
---@return table|nil job
function Subscribe.refresh(feed, more, cb)
    local cursor = more and feed.cursor or nil
    return Subscribe.providers[feed.kind].fetch(feed, cursor, function(items, next_cursor, err)
        if not items then
            logger.warn("subscribe refresh failed", feed.kind, feed.url, err)
            SubDB.update(feed.id, { error = tostring(err or "") })
            return cb(nil, err)
        end
        local added = SubDB.merge(feed.id, items)
        -- 刷新第一页不能把已经翻到更早的游标拉回来。
        local keep = more and (next_cursor or 0) or math.max(feed.cursor or 0, next_cursor or 0)
        SubDB.update(feed.id, { cursor = keep, updated_at = os.time(), error = "" })
        feed.cursor, feed.updated_at = keep, os.time()
        cb(added)
    end)
end

--- 手动添加公众号：撤销之前的取消订阅记录。
---@param mp_id string
function Subscribe.allowMp(mp_id)
    local s = Subscribe.settings()
    if s.mp_removed and s.mp_removed[mp_id] then
        s.mp_removed[mp_id] = nil
        require("utils.settings").save("features.subscribe")
    end
end

--- 默认全订：把微信读书书架上的公众号都加进订阅（用户取消过的跳过）；无书架分组的归「公众号」组。
--- 未登录 / 失败时 cb(nil, err)；成功 cb(新增的订阅行列表)。
---@param cb fun(added: table[]|nil, err: any)
function Subscribe.syncMp(cb)
    return require("source.wechat.client"):shelfSyncAsync(function(data, err)
        if not data then return cb(nil, err) end
        local removed = Subscribe.settings().mp_removed or {}
        local have = {}
        for _idx, feed in ipairs(SubDB.feeds()) do
            if feed.kind == "mp" then have[feed.url] = true end
        end
        local added = {}
        for _idx, a in ipairs(require("source.wechat.mp").accounts(data)) do
            if not have[a.id] and not removed[a.id] then
                local id = SubDB.add({ kind = "mp", url = a.id, title = a.title,
                    grp = a.group ~= "" and a.group or _("公众号") })
                if id then added[#added + 1] = SubDB.feed(id) end
            end
        end
        cb(added)
    end)
end

--- 订阅源的工作目录：订阅在阅读器里是一本按章书（features.subscribe.source，书 id 为订阅 id），
--- 章节 HTML、正文片段（articles/）和图片（images/）都在这本书的目录下。
---@param feed_id integer
---@return string
function Subscribe.dir(feed_id)
    return Paths.bookWorkDir(tostring(feed_id), "subscribe")
end

--- 删订阅连同缓存文件与目录。公众号记进 mp_removed，自动全订时不再加回来。
---@param feed table
function Subscribe.remove(feed)
    if feed.kind == "mp" then
        local s = Subscribe.settings()
        s.mp_removed = s.mp_removed or {}
        s.mp_removed[feed.url] = true
        require("utils.settings").save("features.subscribe")
    end
    SubDB.remove(feed.id)
    require("book.store").clearCache("subscribe", tostring(feed.id))
    require("source.toc").drop("subscribe", tostring(feed.id))
    -- 阅读时登记的隐藏书行（deleted=1）连同章节、注解等依附记录一并撕掉。
    require("book.books_db").remove("subscribe", tostring(feed.id))
end

--- 文章正文片段（含标题 h1），按 guid 缓存：目录变动作废章节文件后重开不必重下。
---@param feed table
---@param item { guid: string, title: string|nil, link: string|nil }
---@param cb fun(html: string|nil, err: any)
---@return table|nil job
function Subscribe.content(feed, item, cb)
    local dir = Subscribe.dir(feed.id)
    local path = dir .. "/articles/" .. require("ffi/sha2").md5(item.guid) .. ".html"
    local f = io.open(path, "rb")
    if f then
        local html = f:read("*a")
        f:close()
        return cb(html)
    end
    Paths.ensureDir(dir .. "/articles")
    local images_dir = Subscribe.settings().images ~= false and dir .. "/images" or nil
    return Subscribe.providers[feed.kind].content(feed, item, images_dir, function(html, err, meta)
        if not html then return cb(nil, err) end
        html = require("features.subscribe.typography").article(item.title or "", html, images_dir ~= nil,
            meta and meta.byline)
        -- 先写临时文件再改名：写到一半断电 / 被杀不会留下半截缓存（下次直接当正文用）。
        local tmp = path .. ".tmp"
        local out = io.open(tmp, "wb")
        if out then
            local ok = out:write(html)
            out:close()
            if not ok or not os.rename(tmp, path) then os.remove(tmp) end
        end
        cb(html)
    end)
end

-- 扩展点登记（features 加载器 require 本模块时执行一次；见 utils/extension.lua）。
local Ext = require("utils.extension")
local function enabled() return require("utils.settings").get("features.subscribe").enabled and true or false end
Ext.add("desktop.tabs", {
    id = "subscribe", text = _("订阅"), icon = "subscriptions", after = "library", enabled = enabled,
    -- 页按需建：总开关关着时底栏没有这一格，从不 require。
    create = function(opts) return require("features.subscribe.page"):new(opts) end,
})
-- 公众号默认全订：打开桌面时把书架上的公众号同步进订阅（成功后 30 分钟内不重复；未登录静默跳过）。
Subscribe.MP_INTERVAL = 30 * 60
Ext.add("desktop.opened", function(desk)
    local s = Subscribe.settings()
    if not s.enabled or os.time() - (s.mp_at or 0) < Subscribe.MP_INTERVAL then return end
    Subscribe.syncMp(function(added, err)
        if not added then return logger.info("subscribe mp sync skipped", err) end
        s.mp_at = os.time()
        require("utils.settings").save("features.subscribe")
        if #added > 0 and desk.plugin and desk.plugin.desktop == desk and desk.tab == "subscribe" then desk:updateView() end
    end)
end)
Ext.add("setting.groups", { id = "subscribe", title = _("订阅"), after = "library" })
-- 远程管理的订阅页（/subscribe.html）与接口（/api/subscribe/<action>，见 features.subscribe.remote）。
Ext.add("web.routes", {
    name = "subscribe",
    dir = (debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or ".") .. "/web",
    assets = { "subscribe.html", "subscribe.js", "subscribe.css" },
    page = {
        href = "/subscribe.html", title = "订阅", title_long = "订阅管理", tile = "tile-green",
        desc = "添加、分组、删除订阅，刷新与 OPML 导入导出。",
        icon = "M6.18 15.64a2.18 2.18 0 1 1 0 4.36 2.18 2.18 0 0 1 0-4.36zM4 4.44A15.56 15.56 0 0 1 19.56 20h-2.83A12.73 12.73 0 0 0 4 7.27V4.44zm0 5.66a9.9 9.9 0 0 1 9.9 9.9h-2.83A7.07 7.07 0 0 0 4 12.93V10.1z",
    },
    l10n = "features.subscribe.l10n.web",
    handle = function(method, action, params, cb) require("features.subscribe.remote").handle(method, action, params, cb) end,
    download = function(action) return require("features.subscribe.remote").download(action) end,
})
-- 隐藏的订阅书源（阅读订阅文章用）：能 resolve，不进源清单。
require("source.registry").registerHidden("subscribe", function() return require("features.subscribe.source") end)

return Subscribe
