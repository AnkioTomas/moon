--[[-- features.subscribe.remote：远程管理接口（列表 / 分组 / 增删改 / 预览 / 排序 / 刷新 / 正文 / OPML）。 --]]
local Assert = require("support.assert")

local rows, next_id = {}, 1
local function find(id) for _, r in ipairs(rows) do if r.id == id then return r end end end
local read_calls = {}
package.loaded["features.subscribe.db"] = {
    KEEP = 600,
    addMany = function(list)
        local added = 0
        for _, f in ipairs(list) do if package.loaded["features.subscribe.db"].add(f) then added = added + 1 end end
        return added, #list - added
    end,
    feeds = function()
        table.sort(rows, function(a, b)
            if a.grp ~= b.grp then return a.grp < b.grp end
            if a.sort ~= b.sort then return a.sort < b.sort end
            return a.title < b.title
        end)
        return rows
    end,
    feed = find,
    add = function(f)
        for _, r in ipairs(rows) do if r.kind == f.kind and r.url == f.url then return nil end end
        rows[#rows + 1] = { id = next_id, kind = f.kind, url = f.url, title = f.title, grp = f.grp or "", unread = 1, updated_at = 0, sort = 0, error = "" }
        next_id = next_id + 1
        return next_id - 1
    end,
    update = function(id, f) local r = find(id); for k, v in pairs(f) do r[k] = v end end,
    renameGroup = function(old, new) for _, r in ipairs(rows) do if r.grp == old then r.grp = new end end end,
    order = function(grp, ids) for i, id in ipairs(ids) do local r = find(id); r.grp, r.sort = grp, i end end,
    items = function(_id, _page, _size, read)
        _G.__sub_items_read = read
        return { { guid = "g1", title = "文一", link = "https://a/1", read = false } }, 1
    end,
    summary = function() return nil end,
    markRead = function(id, guid) read_calls[#read_calls + 1] = id .. ":" .. tostring(guid) end,
}
local store = { enabled = true }
package.loaded["utils.settings"] = { get = function() return store end, save = function() end }
local removed = {}
package.loaded["features.subscribe"] = {
    settings = function() return store end,
    privateHost = function(url) return url:match("^https?://192%.168%.") ~= nil or url:match("^https?://localhost") ~= nil end,
    probe = function(kind, url, _f, cb)
        if url:find("bad") then return cb(nil, "无效") end
        cb({ kind = kind, url = url, title = "T" })
    end,
    providers = { rss = {
        fetch = function(_feed, _c, cb) cb({ { title = "一", link = "https://a/1" }, { title = "二", link = "" } }) end,
        content = function(_feed, _item, images, cb) Assert.is_nil(images); cb("<p>正文<img src='x'></p>") end,
    } },
    remove = function(feed) removed[#removed + 1] = feed.id; for i, r in ipairs(rows) do if r == feed then table.remove(rows, i) end end end,
    refresh = function(feed, _more, cb) if feed.id == 2 then return cb(nil, "HTTP 500") end cb(3) end,
    content = function(_feed, _item, cb) cb("<h1>文一</h1><script>x()</script><img src='/local.jpg'><p>内容</p>") end,
}
package.loaded["features.subscribe.setting"] = nil
-- 后台刷新任务替身：直接转给 features.subscribe.refresh 桩（队列行为见 refresh_spec）。
package.loaded["features.subscribe.refresh"] = { start = function(feeds, o)
    local f = feeds[1]
    package.loaded["features.subscribe"].refresh(f, o.more, function(a, e) o.on_feed(f, a, e) end)
end }
package.loaded["features.subscribe.remote"] = nil
local Remote = require("features.subscribe.remote")

local function call(method, action, params)
    local st, res
    Remote.handle(method, action, params, function(s, r) st, res = s, r end)
    return st, res
end

-- 添加：试拉；重复 409；坏类型 400；解析失败 422
Assert.eq(call("POST", "add", { kind = "rss", url = "https://a/feed", group = "科技" }), 201)
Assert.eq(call("POST", "add", { kind = "rss", url = "https://a/feed" }), 409)
Assert.eq(call("POST", "add", { kind = "mp", url = "x" }), 400)
Assert.eq(call("POST", "add", { kind = "rss", url = "https://bad" }), 422)
local st = call("POST", "add", { kind = "site", url = "https://b/", title = "网站B", checked = true })
Assert.eq(st, 201)
Assert.eq(rows[2].title, "网站B")

-- 预览：标题、前几篇、首篇正文摘录（纯文本）
local _, pv = call("POST", "preview", { kind = "rss", url = "https://a/feed" })
Assert.eq(pv.title, "T")
Assert.eq(#pv.items, 2)
Assert.eq(pv.excerpt, "正文")
Assert.eq(call("POST", "preview", { kind = "rss", url = "" }), 400)

-- 分组：新建空组也出现在列表；重名 409；改名带走订阅；删组订阅回到未分组
Assert.eq(call("POST", "group", { op = "create", name = "空组" }), 200)
Assert.eq(call("POST", "group", { op = "create", name = "科技" }), 409)
local _, list = call("GET", "list", {})
local names = {}
for _, g in ipairs(list.groups) do names[#names + 1] = g.name .. ":" .. g.count end
Assert.eq(table.concat(names, ","), "空组:0,科技:1")
Assert.is_nil(list.auto, "自动离线下载已移除")
call("POST", "group", { op = "rename", name = "科技", to = "技术" })
Assert.eq(find(1).grp, "技术")
Assert.eq(call("POST", "group", { op = "rename", name = "无", to = "x" }), 404)

-- 移组 / 组内排序
call("POST", "move", { ids = { 2 }, group = "技术" })
Assert.eq(find(2).grp, "技术")
Assert.eq(find(2).sort, 2)
call("POST", "reorder", { group = "技术", ids = { 2, 1 } })
Assert.eq(find(2).sort, 1)
Assert.eq(find(1).sort, 2)
call("POST", "group", { op = "delete", name = "技术" })
Assert.eq(find(1).grp, "")

-- 改名：空名 400
Assert.eq(call("POST", "update", { id = 1, title = " " }), 400)
call("POST", "update", { id = 1, title = "新名", group = "阅读" })
Assert.eq(find(1).title, "新名")
Assert.eq(call("POST", "update", { id = 99, title = "x" }), 404)

-- 刷新：成功回新增数；失败 502 带原因
local s1, r1 = call("POST", "refresh", { id = 1 })
Assert.eq(s1, 200); Assert.eq(r1.added, 3)
local s2, r2 = call("POST", "refresh", { id = 2 })
Assert.eq(s2, 502); Assert.eq(r2.error, "HTTP 500")

-- 文章列表 / 正文（去脚本、去图片）/ 标已读
local _, items = call("GET", "items", { id = "1" })
Assert.is_nil(_G.__sub_items_read, "缺省不筛")
call("GET", "items", { id = "1", read = "0" })
Assert.eq(_G.__sub_items_read, false, "read=0 只要未读")
call("GET", "items", { id = "1", read = "1" })
Assert.eq(_G.__sub_items_read, true, "read=1 只要已读")
call("GET", "items", { id = "1" })
Assert.eq(items.total, 1)
Assert.eq(call("GET", "article", { id = "1", guid = "g1" }), 404, "有副作用的接口不接受 GET")
local _, art = call("POST", "article", { id = "1", guid = "g1" })
Assert.is_nil(art.html:find("<script", 1, true))
-- 本地图路径被 clean 去掉后整篇没图：退回链接本身当图
Assert.eq(art.html:match("<img[^>]*>"), '<img src="https://a/1" referrerpolicy="no-referrer" loading="lazy" alt="">')
Assert.eq(call("POST", "article", { id = "1", guid = "nope" }), 404)
call("POST", "read", { id = 1, guid = "g1" })
call("POST", "read", { id = 1 })
Assert.eq(table.concat(read_calls, ","), "1:g1,1:nil")

-- OPML：导出不含公众号、带分组，可解析回来；导入回统计
rows[#rows + 1] = { id = 50, kind = "mp", url = "MP_WXS_1", title = "号", grp = "", unread = 0, sort = 0, error = "" }
local opml = Remote.opml()
Assert.is_nil(opml:find("MP_WXS_1", 1, true))
local parsed = Remote.parseOpml(opml)
Assert.eq(#parsed, 2)
local imported = Remote.parseOpml([[<opml><body><outline text="A &amp; B"><outline type="rss" text="X" xmlUrl="https://x/rss"/></outline>
<outline title="Y" xmlUrl='https://y/rss'/></body></opml>]])
Assert.eq(imported[1].grp, "A & B")
Assert.eq(imported[2].title, "Y")
local _, ir = call("POST", "import", { opml = '<outline xmlUrl="https://z/rss" text="Z"/><outline xmlUrl="https://a/feed" text="A"/>' })
Assert.eq(ir.added, 1); Assert.eq(ir.skipped, 1); Assert.eq(ir.total, 2)
Assert.eq(call("POST", "import", { opml = "<opml/>" }), 422)

-- 真实 OPML（tidings-rss 的 release 包节选）：BOM、单引号 XML 声明、嵌套分类 → 分组、实体、emoji。
do
    local f = assert(io.open("tests/features/subscribe/fixtures/tidings-sample.opml", "rb"))
    local text = f:read("*a")
    f:close()
    Assert.eq(text:sub(1, 3), "\239\187\191", "fixture 带 BOM")
    local list = Remote.parseOpml(text)
    Assert.eq(#list, 6)
    Assert.eq(list[1].grp, "🤖 Artificial Intelligence")
    Assert.eq(list[1].url, "https://blog.google/technology/ai/rss/")
    Assert.eq(list[3].title, "AI 开发者日报")
    Assert.eq(list[4].grp, "🛠️ Engineering & Technology")
    Assert.eq(list[6].url, "https://maki49.github.io/feed.xml")
end
-- 刁钻写法：属性名大小写、单引号、属性顺序、标题里的 >、注释、重复地址、非 http 地址、多层嵌套取最近一层分类。
do
    local list = Remote.parseOpml([[<?xml version="1.0"?><opml><body>
<!-- <outline xmlUrl="https://comment/rss"/> -->
<OUTLINE TEXT="外层"><outline text='内层'>
  <outline XMLURL='https://a.com/rss' type="RSS" title="a > b &lt;c&gt;"/>
  <outline type="site" xmlurl="https://s.com/" text="站"></outline>
</outline>
<outline xmlUrl="https://b.com/rss" text="B"/>
</OUTLINE>
<outline xmlUrl="https://a.com/rss" text="重复"/>
<outline xmlUrl="javascript:alert(1)" text="坏"/>
</body></opml>]])
    Assert.eq(#list, 3)
    Assert.eq(list[1].url, "https://a.com/rss")
    Assert.eq(list[1].title, "a > b <c>")
    Assert.eq(list[1].grp, "内层")
    Assert.eq(list[2].kind, "site")
    Assert.eq(list[2].grp, "内层")
    Assert.eq(list[3].grp, "外层")
end
-- 从网址导入：下载失败回 502；拿到 OPML 就导入，分组登记进设置。
do
    local S = package.loaded["features.subscribe"]
    local pages = { ["https://opml.test/x.opml"] = '<opml><body><outline text="新组"><outline xmlUrl="https://n1.com/rss" text="N1"/></outline></body></opml>' }
    S.fetchText = function(url, cb) local b = pages[url]; cb(b, b == nil and "HTTP 404" or nil) end
    local code, r = call("POST", "import", { url = "opml.test/x.opml" })
    Assert.eq(code, 200)
    Assert.eq(r.added, 1)
    local has = false
    for _i, g in ipairs(store.groups or {}) do if g == "新组" then has = true end end
    Assert.is_true(has, "导入的分组登记进设置")
    Assert.eq(call("POST", "import", { url = "https://none.test/x" }), 502)
    pages["https://html.test/"] = "<html>not opml</html>"
    Assert.eq(call("POST", "import", { url = "https://html.test/" }), 422)
    -- 添加对话框里试拉 OPML 地址：不报「不是有效的 RSS」，回 opml=true 让网页改走导入。
    local code2, p = call("POST", "preview", { kind = "rss", url = "https://bad.opml.test/x.opml" })
    Assert.eq(code2, 422, "不是 OPML 时照常报错")
    pages["https://bad.opml.test/x.opml"] = pages["https://opml.test/x.opml"]
    code2, p = call("POST", "preview", { kind = "rss", url = "https://bad.opml.test/x.opml" })
    Assert.eq(code2, 200)
    Assert.is_true(p.opml)
    Assert.eq(p.count, 1)
    Assert.eq(p.url, "https://bad.opml.test/x.opml")
end

-- 批量删除
local _, rr = call("POST", "remove", { ids = { 1, 2, 999 } })
Assert.eq(rr.removed, 2)
Assert.eq(call("GET", "nope", {}), 404)

-- ── 纯文本批量编辑 ──
rows, next_id = {}, 1
store.groups = {}
local DB = package.loaded["features.subscribe.db"]
DB.add({ kind = "rss", url = "https://a/feed", title = "甲", grp = "" })
DB.add({ kind = "rss", url = "https://b/feed", title = "乙", grp = "科技" })
DB.add({ kind = "mp", url = "MP_WXS_1", title = "号", grp = "科技" })
local text = Remote.serialize()
Assert.eq(text, "甲 | https://a/feed\n\n# 科技\n乙 | https://b/feed\n号 | MP_WXS_1\n")

local parsed, bad = Remote.parseText("https://x.com/rss\n新标题 https://y.com/\nz.com/feed | 阅读\n# 组\n标 | https://w/ | 别组\n乱写一行\n")
Assert.eq(parsed[1].url, "https://x.com/rss"); Assert.is_nil(parsed[1].title); Assert.eq(parsed[1].group, "")
Assert.eq(parsed[2].title, "新标题")
Assert.eq(parsed[3].url, "https://z.com/feed"); Assert.eq(parsed[3].group, "阅读")
Assert.eq(parsed[4].group, "别组")
Assert.eq(bad[1].text, "乱写一行")
-- 标题像域名或含竖线：地址取最右边像地址的那段，标题原样保留（序列化再解析不产生变更）
local p2 = Remote.parseText("Surmon.me | https://surmon.me/rss.xml\nA | B | https://c/feed\n")
Assert.eq(p2[1].url, "https://surmon.me/rss.xml"); Assert.eq(p2[1].title, "Surmon.me"); Assert.eq(p2[1].group, "")
Assert.eq(p2[2].url, "https://c/feed"); Assert.eq(p2[2].title, "A | B")

-- 预览：甲改名并移组、乙删除、号改名忽略只移组、新增 x、MP 新号无效
local edited = "# 新组\n甲二 | https://a/feed\n改不了 | MP_WXS_1\n# 科技\nhttps://x.com/rss\nMP_WXS_9\n"
local _, pl = call("POST", "batch", { text = edited })
Assert.eq(#pl.add, 1); Assert.eq(pl.add[1].group, "科技")
Assert.eq(#pl.remove, 1); Assert.eq(pl.remove[1].title, "乙")
Assert.eq(#pl.rename, 1); Assert.eq(pl.rename[1].to, "甲二")
Assert.eq(#pl.move, 2)
Assert.eq(pl.invalid[1].text, "MP_WXS_9")
Assert.eq(#rows, 3, "预览不改数据")

-- 执行：新地址先按 RSS 识别，不行按网站
local S = package.loaded["features.subscribe"]
local probes = {}
S.probe = function(kind, url, _f, cb) probes[#probes + 1] = kind; if kind == "rss" then return cb(nil, "no") end cb({ kind = kind, url = url, title = "X站" }) end
local st2, res2 = call("POST", "batch", { text = edited, apply = true })
Assert.eq(st2, 200)
Assert.eq(res2.added, 1); Assert.eq(res2.removed, 1)
Assert.eq(table.concat(probes, ","), "rss,site")
local x
for _, r in ipairs(rows) do if r.url == "https://x.com/rss" then x = r end end
Assert.eq(x.kind, "site"); Assert.eq(x.title, "X站"); Assert.eq(x.grp, "科技")
Assert.eq(find(1).title, "甲二"); Assert.eq(find(1).grp, "新组")
Assert.eq(find(3).title, "号"); Assert.eq(find(3).grp, "新组"); Assert.eq(find(3).sort, 2)
Assert.eq(table.concat(store.groups, ","), "新组,科技")
local _, txt = call("GET", "text", {})
Assert.matches(txt.text, "# 新组")

-- 分组改名到已有组名 = 并入：订阅追加到目标组尾，设置里不出现重复组。
do
    local a = rows[1]
    store.groups = { "甲组", "乙组" }
    for _, r in ipairs(rows) do r.grp = "" end
    a.grp = "甲组"
    rows[2].grp = "乙组"
    Assert.eq(call("POST", "group", { op = "rename", name = "甲组", to = "乙组" }), 200)
    Assert.eq(a.grp, "乙组")
    Assert.eq(a.sort, 2, "追加到目标组尾")
    Assert.eq(table.concat(store.groups, ","), "乙组")
    Assert.eq(call("POST", "group", { op = "rename", name = "乙组", to = "乙组" }), 200, "同名改名无操作")
    Assert.eq(table.concat(store.groups, ","), "乙组")
end

-- 网页发起的抓取拒绝局域网 / 本机地址（preview / add / import / batch）。
do
    Assert.eq(call("POST", "preview", { kind = "rss", url = "http://192.168.1.5/feed" }), 400)
    Assert.eq(call("POST", "add", { kind = "rss", url = "localhost:8080/feed" }), 400)
    local s, r = call("POST", "import", { url = "http://192.168.0.1/a.opml" })
    Assert.eq(s, 400)
    Assert.eq(r.error, "不允许访问局域网或本机地址")
    local _, res = call("POST", "batch", { text = "http://192.168.3.3/rss\n", apply = true })
    Assert.eq(res.added, 0)
    Assert.eq(res.failed[1].error, "不允许访问局域网或本机地址")
end

-- 导入走 addMany（一个事务）：新增 / 已存在计数。
do
    local opml = '<opml><body><outline text="组"><outline xmlUrl="https://n1/feed" text="N1"/>'
        .. '<outline xmlUrl="https://n2/feed" text="N2"/></outline></body></opml>'
    local s, r = call("POST", "import", { opml = opml })
    Assert.eq(s, 200)
    Assert.eq(r.added, 2)
    s, r = call("POST", "import", { opml = opml })
    Assert.eq(r.added, 0)
    Assert.eq(r.skipped, 2)
end

-- 预览正文按白名单清洗：脚本 / 样式 / 内嵌框 / 媒体 / 事件属性 / javascript: 链接全部去掉。
do
    local html = Remote.clean('<p onclick="x()">a</p><link rel="stylesheet" href="https://t/x.css"><iframe src="https://t"></iframe>'
        .. '<video src="https://t/v.mp4"></video><div style="background:url(https://t/b.png)">b</div><SCRIPT>y()</SCRIPT>')
    Assert.is_nil(html:find("onclick", 1, true))
    Assert.is_nil(html:find("<link", 1, true))
    Assert.is_nil(html:find("iframe", 1, true))
    Assert.is_nil(html:find("video", 1, true))
    Assert.is_nil(html:find("https://t/b.png", 1, true))
    Assert.is_nil(html:find("y()", 1, true))
    Assert.matches(html, "<p>a</p>")
    Assert.is_nil(html:find("style", 1, true))
    local h2 = Remote.clean('<a href="javascript:alert(1)">x</a><a href=" JaVa\tscript:y">y</a><a href="https://e.com/?a=1&b=2" onmouseover="z()">ok</a>'
        .. '<!-- <script>c()</script> --><mp-x data-a="1">t</mp-x><svg><a href="https://e">s</a></svg><td colspan="2" style="x">c</td><img src=x onerror=alert(1)>')
    Assert.is_nil(h2:find("javascript", 1, true))
    Assert.is_nil(h2:find("script", 1, true))
    Assert.is_nil(h2:find("on%a+="))
    Assert.is_nil(h2:find("mp%-x"))
    Assert.is_nil(h2:find("<svg", 1, true))
    Assert.is_nil(h2:find("<img", 1, true))
    Assert.matches(h2, '<a href="https://e.com/%?a=1&amp;b=2" rel="noopener noreferrer" target="_blank">ok</a>')
    Assert.matches(h2, '<td colspan="2">c</td>')
    Assert.matches(h2, ">t<")
    -- 图片只留 https / data:image（非 svg），不带 Referer；本地路径、http、javascript:、svg 一律去掉。
    local h3 = Remote.clean('<img src="https://mmbiz.qpic.cn/a/640?wx_fmt=png&amp;x=1" style="w" onload="z()">'
        .. '<img src="/mnt/us/a.jpg"><img src="http://e/a.png"><img src="javascript:x"><img src="data:image/svg+xml;base64,AA">'
        .. '<img src="data:image/png;base64,iVBO">')
    Assert.matches(h3, '<img src="https://mmbiz.qpic.cn/a/640%?wx_fmt=png&amp;x=1" referrerpolicy="no%-referrer" loading="lazy" alt="">')
    Assert.matches(h3, 'src="data:image/png;base64,iVBO"')
    Assert.is_nil(h3:find("/mnt/us", 1, true))
    Assert.is_nil(h3:find("http://", 1, true))
    Assert.is_nil(h3:find("javascript", 1, true))
    Assert.is_nil(h3:find("svg", 1, true))
    Assert.is_nil(h3:find("onload", 1, true))
    Assert.is_nil(h3:find("style", 1, true))
end

-- OPML 导出走 download（路由层直接回附件）；其他动作不是附件。
Assert.eq(Remote.download("opml").filename, "moon-subscriptions.opml")
Assert.is_nil(Remote.download("list"))
