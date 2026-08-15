local Assert = require("support.assert")
local Parser = require("source.rss.parser")

local rss = [=[
<?xml version="1.0"?>
<rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/">
  <channel>
    <title>Example &amp; News</title>
    <description>Feed intro</description>
    <item>
      <title>First &amp; best</title>
      <link>https://example.com/posts/1</link>
      <guid>post-1</guid>
      <pubDate>Sat, 15 Aug 2026 12:00:00 GMT</pubDate>
      <content:encoded><![CDATA[
        <p>Hello</p><img src="../img/a.jpg"><a href="/more">More</a>
        <script>alert(1)</script>
      ]]></content:encoded>
    </item>
    <item>
      <title>Second</title>
      <link>/posts/2</link>
      <description><![CDATA[<p>Summary</p>]]></description>
    </item>
  </channel>
</rss>
]=]

do
    local feed, err = Parser.parse(rss, "https://example.com/feed/rss.xml")
    Assert.eq(err, nil)
    Assert.eq(feed.title, "Example & News")
    Assert.eq(feed.intro, "Feed intro")
    Assert.eq(#feed.items, 2)
    Assert.eq(feed.items[1].uid, "post-1")
    Assert.eq(feed.items[1].title, "First & best")
    Assert.is_true(feed.items[1].content:find(
        'src="https://example.com/img/a.jpg"', 1, true) ~= nil)
    Assert.is_true(feed.items[1].content:find(
        'href="https://example.com/more"', 1, true) ~= nil)
    Assert.is_true(feed.items[1].content:find("<script", 1, true) == nil)
    Assert.eq(feed.items[2].link, "https://example.com/posts/2")
    Assert.is_true(feed.items[2].content:find("<p>Summary</p>", 1, true) ~= nil)
end

local atom = [=[
﻿<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>Atom Feed</title>
  <subtitle>Atom intro</subtitle>
  <entry>
    <title>Atom post</title>
    <id>tag:example.com,2026:1</id>
    <link rel="self" href="https://example.com/api/1"/>
    <link rel="alternate" href="/article/1"/>
    <updated>2026-08-15T12:00:00Z</updated>
    <content type="html">&lt;p&gt;Atom body&lt;/p&gt;</content>
  </entry>
</feed>
]=]

do
    local feed, err = Parser.parse(atom, "https://example.com/atom.xml")
    Assert.eq(err, nil)
    Assert.eq(feed.title, "Atom Feed")
    Assert.eq(#feed.items, 1)
    Assert.eq(feed.items[1].uid, "tag:example.com,2026:1")
    Assert.eq(feed.items[1].link, "https://example.com/article/1")
    Assert.eq(feed.items[1].date, "2026-08-15T12:00:00Z")
    Assert.is_true(feed.items[1].content:find("<p>Atom body</p>", 1, true) ~= nil)
end

do
    Assert.eq(Parser.normalizeUrl(" EXAMPLE.COM/feed/ "),
        "https://example.com/feed")
    Assert.eq(Parser.normalizeUrl("HTTPS://EXAMPLE.COM/Feed"),
        "https://example.com/Feed")
    Assert.eq(Parser.absoluteUrl("https://example.com/a/b.xml", "../x"),
        "https://example.com/x")
    Assert.eq(Parser.absoluteUrl("https://example.com/a/b.xml?old=1", "?new=1"),
        "https://example.com/a/b.xml?new=1")
    Assert.eq(Parser.absoluteUrl("https://example.com/a/b.xml", "mailto:a@example.com"),
        "mailto:a@example.com")
    local feed, err = Parser.parse("<html/>", "https://example.com/feed")
    Assert.is_nil(feed)
    Assert.is_true(type(err) == "string")
end
