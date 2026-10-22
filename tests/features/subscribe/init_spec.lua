--[[-- features.subscribe：试拉（RSS 网页里找 alternate 订阅源）、刷新游标、RSS 摘要 → 抓原文 Readability、正文片段缓存。 --]]

local Assert = require("support.assert")
local Config = require("support.config")
require("support.stubs").install()

local web = {}
local redirects = {}
local CHUNK = 1024 * 1024
local delivered, cancelled = 0, 0
local async_mode, pending = false, nil
--- 流式桩：按 1MB 一块同步吐 body；取消后不再吐，但照样 on_done（与真实 stream 一致）。
package.loaded["http.request"] = {
    stream = function(opts, h)
        local job = { stopped = false }
        function job:cancel() if not self.stopped then self.stopped = true; cancelled = cancelled + 1 end end
        local url = opts.url
        local loc = redirects[url]
        if loc then
            h.on_headers(302, { Location = loc })
            h.on_done("HTTP 302")
            return job
        end
        local body = web[url]
        local function run()
            h.on_headers(body and 200 or 404, {})
            if body then
                for i = 1, #body, CHUNK do
                    if job.stopped then break end
                    delivered = delivered + 1
                    h.on_data(body:sub(i, i + CHUNK - 1))
                end
            end
            h.on_done(job.stopped and "cancelled" or (body == nil and "HTTP 404" or nil))
        end
        -- 真实 stream 是异步的（返回句柄后才回调）；async 模式下等 pump()。
        if async_mode then pending = run else run() end
        return job
    end,
    header = function(res, name) return res.headers and res.headers[name] end,
}
package.loaded["http.request.header"] = { forRequest = function(_extra, accept) return { Accept = accept } end }
-- fork 子进程在单测里同步跑（真实路径见 workers.job）。
package.loaded["workers.job"] = { run = function(worker, opts) opts.on_done(worker()); return { cancel = function() end } end }
package.loaded["http.timeout"] = { net = function() return 1 end }
local merged, updates, summaries = {}, {}, {}
package.loaded["features.subscribe.db"] = {
    merge = function(id, items) merged[id] = items; return #items end,
    feed = function() return nil end,
    update = function(id, fields) updates[id] = fields end,
    summary = function(_id, guid) return summaries[guid] end,
}
local mp_calls = {}
package.loaded["source.wechat.mp"] = {
    PAGE = 2,
    fetchArticlesAsync = function(_id, offset, cb)
        mp_calls[#mp_calls + 1] = offset
        local items = offset == 0 and { { guid = "a" }, { guid = "b" } } or offset == 6 and { { guid = "c" }, { guid = "d" } } or offset == 8 and { { guid = "e" } } or {}
        cb(items, nil, #items)
    end,
}
local dir = Config.dir() .. "/subscribe_init_spec"
package.loaded["utils.paths"] = { cacheDir = function() return dir end,
    bookWorkDir = function(stable_id, id) return dir .. "/" .. id .. "/" .. stable_id end, ensureDir = function(p) os.execute("mkdir -p '" .. p .. "'") end }
local sub_settings = { images = false }
package.loaded["utils.settings"] = { get = function() return sub_settings end, save = function() end }
package.loaded["features.subscribe"] = nil
local Subscribe = require("features.subscribe")

local rss = '<rss><channel><title>源</title><item><title>一</title><link>https://a.com/1</link></item></channel></rss>'
web["https://a.com/feed"] = rss
web["https://a.com/"] = '<html><head><link rel="alternate" type="application/rss+xml" href="/feed"></head></html>'

-- 试拉：给的是网页时顺着 alternate 找到订阅源；没写协议补 https。
local got
Subscribe.probe("rss", "a.com/", nil, function(feed) got = feed end)
Assert.eq(got.url, "https://a.com/feed")
Assert.eq(got.title, "源")
Subscribe.probe("rss", "https://none.com", nil, function(feed, err) got = { feed, err } end)
Assert.eq(got[1], nil)

-- 网页订阅（page）订阅的是网页本身：一个条目，链接是页面地址；正文不变 guid 不变，变了才出新条目。
do
    web["https://page.test/"] = "<html><head><title>公告</title></head><body><article><p>第一版</p><a href='/x1'>这是一条足够长的链接标题</a></article></body></html>"
    local function items()
        local out
        Subscribe.providers.page.fetch({ url = "https://page.test/" }, nil, function(i) out = i end)
        return out
    end
    local a, b = items(), items()
    Assert.len(a, 1)
    Assert.eq(a[1].title, "公告")
    Assert.eq(a[1].link, "https://page.test/")
    Assert.eq(a[1].guid, b[1].guid)
    web["https://page.test/"] = web["https://page.test/"]:gsub("第一版", "第二版")
    Assert.is_true(items()[1].guid ~= a[1].guid, "正文变了出新条目")
    -- 网站订阅（site）取页面里的文章链接
    web["https://page.test/"] = "<body><a href='/x1'>这是一条足够长的链接标题</a></body>"
    local links
    Subscribe.providers.site.fetch({ url = "https://page.test/", filter = "" }, nil, function(i) links = i end)
    Assert.eq(links[1].link, "https://page.test/x1")
    web["https://page.test/"] = nil
end

-- 跳转自己跟：相对 Location（ghfast.top 的 `/https://github.com/...`）按当前地址补全，保留路径里的 //；最多 5 跳。
do
    redirects["https://ghfast.top/https://github.com/o/r/releases/latest/download/all.opml"] = "/https://github.com/o/r/releases/download/v1/all.opml"
    web["https://ghfast.top/https://github.com/o/r/releases/download/v1/all.opml"] = "<opml/>"
    local body, err
    Subscribe.fetchText("https://ghfast.top/https://github.com/o/r/releases/latest/download/all.opml", function(b, e) body, err = b, e end)
    Assert.eq(body, "<opml/>")
    Assert.is_nil(err)
    redirects["https://loop.test/a"] = "/a"
    Subscribe.fetchText("https://loop.test/a", function(b, e) body, err = b, e end)
    Assert.is_nil(body)
    Assert.is_true(err ~= nil, "循环跳转有上限")
end

-- 超过上限边收边断：不把整页下完再判断。
do
    web["https://big.test/"] = string.rep("x", 5 * CHUNK)
    delivered, cancelled = 0, 0
    local body, err
    async_mode = true
    Subscribe.fetchText("https://big.test/", function(b, e) body, err = b, e end)
    async_mode = false
    pending()
    Assert.is_nil(body)
    Assert.eq(err, "页面太大，无法解析")
    Assert.eq(cancelled, 1, "超限即取消连接")
    Assert.is_true(delivered <= 4, "超限后不再收")
    web["https://big.test/"] = nil
end

-- 网页发起（public）的抓取拒绝局域网 / 本机地址，跳转到内网也拦；设备自己的不受限。
do
    for _idx, u in ipairs({ "http://localhost/x", "http://127.0.0.1:8080/", "http://192.168.1.2/", "http://10.0.0.1",
        "http://172.20.1.1/", "http://169.254.169.254/latest", "http://[::1]/", "http://[fd00::1]/", "http://nas.local/",
        "http://2130706433/", "http://user@192.168.0.1/", "file:///etc/passwd" }) do
        Assert.is_true(Subscribe.privateHost(u), u)
    end
    for _idx, u in ipairs({ "https://a.com/feed", "http://8.8.8.8/", "https://172.32.0.1/", "https://[2001:db8::1]/" }) do
        Assert.is_false(Subscribe.privateHost(u), u)
    end
    local body, err
    Subscribe.fetchText("http://192.168.1.2/opml", function(b, e) body, err = b, e end, true)
    Assert.is_nil(body)
    Assert.eq(err, "不允许访问局域网或本机地址")
    redirects["https://pub.test/r"] = "http://127.0.0.1/secret"
    web["http://127.0.0.1/secret"] = "<opml/>"
    Subscribe.fetchText("https://pub.test/r", function(b, e) body, err = b, e end, true)
    Assert.is_nil(body, "跳转到内网也拦")
    Subscribe.fetchText("https://pub.test/r", function(b, e) body, err = b, e end)
    Assert.eq(body, "<opml/>", "设备上自己的请求不受限")
    local feed
    Subscribe.probe("rss", "http://10.1.1.1/feed", nil, function(f, e) feed, err = f, e end, true)
    Assert.is_nil(feed)
end

-- 试拉找 alternate：A→B→A 绕圈即停，不无限请求。
do
    web["https://ring.test/a"] = '<html><link type="application/rss+xml" href="https://ring.test/b"></html>'
    web["https://ring.test/b"] = '<html><link type="application/rss+xml" href="https://ring.test/a"></html>'
    local done, feed = 0, nil
    Subscribe.probe("rss", "https://ring.test/a", nil, function(f) done, feed = done + 1, f end)
    Assert.eq(done, 1)
    Assert.is_nil(feed)
end

-- 公众号刷新：首页不把已翻到的游标拉回；翻更早一页时游标（= offset，已拉推送组数）按实际组数往后走，不满一页即到底清零。
local feed = { id = 1, kind = "mp", url = "MP_WXS_1", cursor = 6 }
Subscribe.refresh(feed, false, function() end)
Assert.eq(mp_calls[1], 0)
Assert.eq(updates[1].cursor, 6)
Subscribe.refresh(feed, true, function() end)
Assert.eq(mp_calls[2], 6)
Assert.eq(updates[1].cursor, 8)
Subscribe.refresh(feed, true, function() end)
Assert.eq(mp_calls[3], 8)
Assert.eq(updates[1].cursor, 0)

-- RSS 只有短摘要：抓原文跑 Readability；原文抓不到用摘要；不下图时去掉 img。
local para = "这是正文段落，内容足够长，带有逗号，用来给父节点加分，模拟真实文章里的一段话，而不是导航或者广告。"
web["https://a.com/1"] = "<html><body><div class='nav'><a href='/'>首页</a></div><article><p>" .. para .. "</p><p>" .. para
    .. "<img src='/i.png'></p></article></body></html>"
summaries["g1"] = "<p>短摘要</p>"
local rss_feed = { id = 7, kind = "rss", url = "https://a.com/feed" }
local html
Subscribe.content(rss_feed, { guid = "g1", title = "标<题", link = "https://a.com/1" }, function(h) html = h end)
Assert.matches(html, "^<h1>标&lt;题</h1>")
Assert.matches(html, "模拟真实文章")
Assert.is_nil(html:find("短摘要", 1, true))
Assert.is_nil(html:find("<img", 1, true), "关掉图片时不留 img")
Assert.eq(Subscribe.dir(7), dir .. "/subscribe/7", "订阅即 subscribe 源的一本书")
local again
Subscribe.content(rss_feed, { guid = "g1", title = "x", link = "https://gone/" }, function(h) again = h end)
Assert.eq(again, html, "正文片段按 guid 缓存，原文没了也照用")
do
    local lfs = require("libs/libkoreader-lfs")
    for name in lfs.dir(dir .. "/subscribe/7/articles") do
        Assert.is_nil(name:find("%.tmp$"), "缓存先写临时文件再改名，不留 .tmp")
    end
end
-- Readability 子进程失败：退回主线程的 Parse.article，不丢正文。
do
    local real = package.loaded["workers.job"].run
    package.loaded["workers.job"].run = function(_w, opts) opts.on_failed("boom"); return {} end
    local got
    Subscribe.extract("<html><body><article><p>" .. para .. "</p></article></body></html>", "https://a.com/x",
        function(h) got = h end)
    Assert.matches(got, "模拟真实文章")
    package.loaded["workers.job"].run = real
end
summaries["g2"] = "<section class=\"x\"><h1>小标题</h1><p>短摘要二</p></section>"
local g2
Subscribe.content(rss_feed, { guid = "g2", title = "二", link = "https://gone/" }, function(h) g2 = h end)
Assert.matches(g2, "短摘要二")
Assert.is_nil(g2:find("<section", 1, true), "section 换成 div，CRE 不在标题后分页")
Assert.matches(g2, "</div>")
Assert.matches(g2, "<h2>小标题</h2>", "正文 h1 降级，CRE 不在它前面分页")
-- 摘要够长但以省略号结尾 = 被截断：仍抓原文；够长且没截断才直接用；抓到的比摘要还短就用摘要。
do
    local long = string.rep("这是一段很长的摘要。", 80)
    summaries["g3"] = "<p>" .. long .. "…</p>"
    local function bigPage()
        local ps = {}
        for i = 1, 40 do ps[i] = "<p>" .. para .. "第" .. i .. "段，模拟真实文章。</p>" end
        return table.concat(ps)
    end
    web["https://a.com/big"] = "<html><body><article>" .. bigPage() .. "</article></body></html>"
    local g3
    Subscribe.content(rss_feed, { guid = "g3", title = "三", link = "https://a.com/big" }, function(h) g3 = h end)
    Assert.matches(g3, "模拟真实文章", "被截断的长摘要去抓原文")
    summaries["g4"] = "<p>" .. long .. "</p>"
    local g4
    Subscribe.content(rss_feed, { guid = "g4", title = "四", link = "https://a.com/big" }, function(h) g4 = h end)
    Assert.matches(g4, "这是一段很长的摘要", "完整的长正文直接用")
    Assert.is_nil(g4:find("模拟真实文章", 1, true))
    summaries["g5"] = "<p>" .. long .. "…</p>"
    local g5
    Subscribe.content(rss_feed, { guid = "g5", title = "五", link = "https://a.com/1" }, function(h) g5 = h end)
    Assert.matches(g5, "这是一段很长的摘要", "抓到的比摘要还短，用摘要")
end
os.execute("rm -rf '" .. dir .. "'")

-- 删订阅：订阅库、缓存、目录、隐藏书行（及依附的章节 / 注解记录）一并清掉。
local calls = {}
package.loaded["features.subscribe.db"].remove = function(id) calls[#calls + 1] = "db:" .. id end
package.loaded["book.store"] = { clearCache = function(s, id) calls[#calls + 1] = "cache:" .. s .. ":" .. id end }
package.loaded["source.toc"] = { drop = function(s, id) calls[#calls + 1] = "toc:" .. s .. ":" .. id end }
package.loaded["book.books_db"] = { remove = function(s, id) calls[#calls + 1] = "book:" .. s .. ":" .. id end }
Subscribe.remove({ id = 7 })
Assert.eq(table.concat(calls, ","), "db:7,cache:subscribe:7,toc:subscribe:7,book:subscribe:7")

-- 公众号默认全订：书架上的全加（无分组归「公众号」），取消过的不加回来，手动加回撤销记录。
Subscribe.remove({ id = 8, kind = "mp", url = "MP_WXS_2" })
Assert.is_true(sub_settings.mp_removed["MP_WXS_2"])
local db = package.loaded["features.subscribe.db"]
local subs = { { id = 1, kind = "mp", url = "MP_WXS_1" } }
db.feeds = function() return subs end
db.add = function(f) subs[#subs + 1] = { id = #subs + 1, kind = f.kind, url = f.url, grp = f.grp }; return #subs end
db.feed = function(id) return subs[id] end
local shelf
package.loaded["source.wechat.client"] = { shelfSyncAsync = function(_self, cb) cb(shelf, shelf == nil and "未登录" or nil) end }
package.loaded["source.wechat.mp"].accounts = function()
    return { { id = "MP_WXS_1", title = "一", group = "" }, { id = "MP_WXS_2", title = "二", group = "" },
        { id = "MP_WXS_3", title = "三", group = "" }, { id = "MP_WXS_4", title = "四", group = "科技" } }
end
local added, serr
Subscribe.syncMp(function(a, e) added, serr = a, e end)
Assert.is_nil(added)
Assert.eq(serr, "未登录")
shelf = {}
Subscribe.syncMp(function(a) added = a end)
Assert.len(added, 2)
Assert.eq(added[1].url, "MP_WXS_3")
Assert.eq(added[1].grp, "公众号")
Assert.eq(added[2].grp, "科技")
Subscribe.allowMp("MP_WXS_2")
Assert.is_nil(sub_settings.mp_removed["MP_WXS_2"])
Subscribe.syncMp(function(a) added = a end)
Assert.eq(added[1].url, "MP_WXS_2")

-- 远程管理接口经 web.routes 登记（features/remote 不再写死订阅）。
do
    local item
    for _idx, it in ipairs(require("utils.extension").list("web.routes")) do
        if it.name == "subscribe" then item = it end
    end
    Assert.not_nil(item)
    Assert.eq(table.concat(item.assets, ","), "subscribe.html,subscribe.js,subscribe.css")
    Assert.matches(item.dir, "features/subscribe/web$")
    Assert.eq(item.page.href, "/subscribe.html")
    Assert.eq(item.l10n, "features.subscribe.l10n.web")
end

-- 打开桌面触发公众号同步：总开关关着不跑；成功后 30 分钟内不重复；失败（未登录）不记时间，下次再试
do
    local opened = require("utils.extension").list("desktop.opened")
    local hook = opened[#opened]
    local calls, real = 0, Subscribe.syncMp
    local result
    Subscribe.syncMp = function(cb) calls = calls + 1; cb(result, result == nil and "未登录" or nil) end
    local desk = { tab = "home" }
    sub_settings.enabled, sub_settings.mp_at = false, nil
    hook(desk)
    Assert.eq(calls, 0, "总开关关着不同步")
    sub_settings.enabled = true
    hook(desk)
    Assert.eq(calls, 1)
    Assert.is_nil(sub_settings.mp_at, "失败不记时间")
    result = {}
    hook(desk)
    Assert.eq(calls, 2)
    Assert.not_nil(sub_settings.mp_at)
    hook(desk)
    Assert.eq(calls, 2, "30 分钟内不重复")
    Subscribe.syncMp = real
end

-- 纯图摘要（报纸 / 漫画）直接当正文，不去抓原文页（那页可能就是一张图）
do
    local Req = package.loaded["http.request"]
    local real_stream, real_assets = Req.stream, package.loaded["source.assets"]
    local fetched = 0
    Req.stream = function() fetched = fetched + 1 return { cancel = function() end } end
    package.loaded["source.assets"] = { localizeAsync = function(html, _dir, _dl, cb) cb(html) return {} end }
    summaries["pic"] = '<p><img src="https://a.com/1.png"></p>'
    local out
    Subscribe.providers.rss.content({ id = 1, kind = "rss" }, { guid = "pic", link = "https://a.com/p" }, "/tmp/x", function(html) out = html end)
    Assert.eq(fetched, 0)
    Assert.matches(out, "1%.png")
    Req.stream, package.loaded["source.assets"] = real_stream, real_assets
end

-- 图片下载：公网文章的图片不许经跳转落到内网；局域网文章（自建 RSSHub）不限。
do
    local asked, answers = {}, {}
    local Req = package.loaded["http.request"]
    local real_request, real_assets = Req.request, package.loaded["source.assets"]
    Req.request = function(opts, cb)
        asked[#asked + 1] = opts.url
        local to = redirects[opts.url]
        if to then cb({ code = 302, headers = { Location = to } }) else cb({ code = 200, body = "IMG" }) end
        return { cancel = function() end }
    end
    local downloader
    package.loaded["source.assets"] = { localizeAsync = function(_html, _dir, dl, cb) downloader = dl; cb("") return {} end }
    local long = "<p>" .. string.rep("字", 3000) .. "</p>"
    summaries["img"] = long
    local function download(feed_link, url)
        asked, answers = {}, {}
        Subscribe.providers.rss.content({ id = 1, kind = "rss" }, { guid = "img", link = feed_link }, "/tmp/x", function() end)
        downloader(url, function(data) answers[#answers + 1] = data or false end)
    end
    redirects["https://cdn.test/a.png"] = "http://192.168.1.2/x.png"
    download("https://a.com/p", "https://cdn.test/a.png")
    Assert.eq(#asked, 1)
    Assert.eq(answers[1], false)
    -- assets 以 handle.cancel() 调用（不带 self），不能崩
    local handle = downloader("https://cdn.test/z.png", function() end)
    handle.cancel()
    handle:cancel()
    download("https://a.com/p", "https://cdn.test/b.png")
    Assert.eq(answers[1], "IMG")
    redirects["https://cdn.test/a.png"] = "/c.png"
    download("https://a.com/p", "https://cdn.test/a.png")
    Assert.eq(asked[2], "https://cdn.test/c.png")
    Assert.eq(answers[1], "IMG")
    redirects["https://cdn.test/a.png"] = "http://192.168.1.2/x.png"
    download("http://192.168.1.5/p", "https://cdn.test/a.png")
    Assert.eq(asked[2], "http://192.168.1.2/x.png")
    Assert.eq(answers[1], "IMG")
    redirects["https://cdn.test/a.png"] = nil
    Req.request, package.loaded["source.assets"] = real_request, real_assets
end
