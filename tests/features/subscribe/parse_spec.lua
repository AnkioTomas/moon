--[[-- features.subscribe.parse：RSS / Atom 条目、日期、网页链接、整页正文兜底。 --]]

local Assert = require("support.assert")
require("support.stubs").install()
local Parse = require("features.subscribe.parse")

-- 日期：RFC 822 带时区、ISO 8601、纯日期都折成 UTC 秒。
Assert.eq(Parse.time("Mon, 02 Jan 2006 15:04:05 +0800"), 1136185445)
Assert.eq(Parse.time("2006-01-02T07:04:05Z"), 1136185445)
Assert.eq(Parse.time("2006-01-02T15:04:05.123+08:00"), 1136185445)
Assert.eq(Parse.time("Mon, 2 Jan 06 07:04:05 GMT"), 1136185445)
Assert.eq(Parse.time("2006-01-02"), 1136160000)
Assert.eq(Parse.time("昨天"), nil)

-- RSS 2.0：CDATA、实体、guid 缺省用 link、content:encoded 优先。
local rss = [==[<?xml version="1.0"?><rss><channel><title>少数派 &amp; 朋友</title>
<item><title><![CDATA[第一篇 <b>粗</b>]]></title><link>https://a.com/1</link><guid isPermaLink="false">g1</guid>
<pubDate>Mon, 02 Jan 2006 15:04:05 +0800</pubDate><description>摘要</description>
<content:encoded><![CDATA[<p>全文</p>]]></content:encoded></item>
<item><title>第二篇</title><link>https://a.com/2</link><description>&lt;p&gt;只有摘要&lt;/p&gt;</description></item>
</channel></rss>]==]
local feed = Parse.feed(rss)
Assert.eq(feed.title, "少数派 & 朋友")
Assert.len(feed.items, 2)
Assert.eq(feed.items[1].guid, "g1")
Assert.eq(feed.items[1].title, "第一篇 粗")
Assert.eq(feed.items[1].summary, "<p>全文</p>")
Assert.eq(feed.items[1].time, 1136185445)
Assert.eq(feed.items[2].guid, "https://a.com/2")
Assert.eq(feed.items[2].summary, "<p>只有摘要</p>")
Assert.eq(feed.items[2].time, 0)

-- Atom：link 取 alternate，id 作 guid。
local atom = [[<feed xmlns="http://www.w3.org/2005/Atom"><title type="text">博客</title>
<entry><title>A</title><link rel="self" href="https://b.com/self"/><link rel="alternate" href="https://b.com/a?x=1&amp;y=2"/>
<id>tag:b,1</id><updated>2006-01-02T07:04:05Z</updated><content type="html">&lt;p&gt;正文&lt;/p&gt;</content></entry></feed>]]
feed = Parse.feed(atom)
Assert.eq(feed.title, "博客")
Assert.eq(feed.items[1].link, "https://b.com/a?x=1&y=2")
Assert.eq(feed.items[1].guid, "tag:b,1")
Assert.eq(feed.items[1].summary, "<p>正文</p>")
Assert.eq(Parse.feed("<html><body>不是订阅源</body></html>"), nil)

-- 多段 CDATA（阮一峰 Atom）：逐段拼起来，段间空白丢掉，不漏出 "]]>"。
feed = Parse.feed([==[<feed><entry><id>x</id><title>T</title><content type="html">
    <![CDATA[<p>一</p>
]]>
    <![CDATA[<p>二 &amp;</p>]]>
</content></entry></feed>]==])
Assert.eq(feed.items[1].summary, "<p>一</p>\n<p>二 &amp;</p>")

-- 网页链接：同站、像标题的长链接；相对地址补全、去锚点、去重；filter 只认 href 子串（可跨站）。
local page = [[<html><head><title>新闻 &amp; 资讯</title></head><body><nav><a href="/">首页</a></nav>
<a href="/news/1.html#top">这是一条足够长的新闻标题一</a><a href="news/2.html">这是一条足够长的新闻标题二</a>
<a href="/news/1.html">这是一条足够长的新闻标题一</a><a href="https://other.com/x">外站的一条足够长的标题啊</a>
<a href="javascript:void(0)">这是一个足够长的脚本链接文字</a><script>"<a href='/s'>脚本里的链接也足够长了吧</a>"</script></body></html>]]
Assert.eq(Parse.title(page), "新闻 & 资讯")
local links = Parse.links(page, "https://c.com/list/")
Assert.len(links, 2)
Assert.eq(links[1].link, "https://c.com/news/1.html")
Assert.eq(links[2].link, "https://c.com/list/news/2.html")
links = Parse.links(page, "https://c.com/list/", "other.com")
Assert.len(links, 1)
Assert.eq(links[1].title, "外站的一条足够长的标题啊")

-- 整页兜底：去导航 / 脚本，取 article，懒加载图换 src。
local body = Parse.article('<body><nav>菜单</nav><article><p>正文</p><img data-src="https://i/1.png" src="data:x" width="9"></article></body>')
Assert.eq(body, '<p>正文</p><img src="https://i/1.png"/>')
Assert.eq(Parse.article("<body><script>x</script></body>"), nil)

-- Cloudflare 邮箱保护：data-cfemail 元素与 email-protection 链接还原成明文 / mailto。
local cf = [[<p>联系<a href="/cdn-cgi/l/email-protection#422302206c212d">邮件</a>（<span class="__cf_email__" data-cfemail="422302206c212d">[email&#160;protected]</span>）</p>]]
Assert.eq(Parse.cfEmail(cf), [[<p>联系<a href="mailto:a@b.co">邮件</a>（a@b.co）</p>]])
Assert.eq(Parse.cfEmail("<p>无</p>"), "<p>无</p>")
