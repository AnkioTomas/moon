--[[-- OPDS Atom mapper 离线用例（Calibre-Web / Komga / COPS 形态样本）。 @module tests.opds.mapper_spec --]]

local Assert = require("support.assert")
package.preload["json"] = function()
    return { decode = require("support.json_stub").decode }
end
package.loaded["json"] = nil
package.loaded["opds.mapper"] = nil
local Mapper = require("opds.mapper")

-- Calibre-Web 根目录：纯导航 feed，搜索同时给 OpenSearch 描述和直接模板。
local CALIBRE_ROOT = [[<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom" xmlns:dc="http://purl.org/dc/terms/">
  <id>urn:uuid:2853dacf-ed79-42f5-8e8a-a7bb3d1ae6a2</id>
  <link rel="self" href="/opds" type="application/atom+xml;profile=opds-catalog;type=feed;kind=navigation"/>
  <link rel="start" title="Start" href="/opds" type="application/atom+xml;profile=opds-catalog;type=feed;kind=navigation"/>
  <link rel="search" href="/opds/osd" type="application/opensearchdescription+xml"/>
  <link type="application/atom+xml" rel="search" title="Search" href="/opds/search/{searchTerms}" />
  <title>Calibre-Web</title>
  <entry>
    <title>Recently added Books</title>
    <link href="/opds/new" type="application/atom+xml;profile=opds-catalog"/>
    <id>/opds/new</id>
    <content type="text">The latest Books</content>
  </entry>
  <entry>
    <title>Authors &amp; Series</title>
    <link rel="subsection" href="/opds/author" type="application/atom+xml;profile=opds-catalog;kind=navigation"/>
    <id>/opds/author</id>
  </entry>
  <entry>
    <title>Broken</title>
    <id>/opds/broken</id>
  </entry>
</feed>]]

local feed = Mapper.feed(CALIBRE_ROOT, "http://nas:8083/opds")
Assert.eq(feed.title, "Calibre-Web")
Assert.len(feed.items, 2)
Assert.eq(feed.items[1].title, "Recently added Books")
Assert.eq(feed.items[1].feed, "http://nas:8083/opds/new")
Assert.is_nil(feed.items[1].stable_id)
Assert.eq(feed.items[2].title, "Authors & Series")
Assert.eq(feed.items[2].feed, "http://nas:8083/opds/author")
Assert.eq(feed.search_osd, "http://nas:8083/opds/osd")
Assert.eq(feed.search_template, "http://nas:8083/opds/search/{searchTerms}")
Assert.is_nil(feed.next)

-- Calibre-Web 书籍 feed：多格式择优、封面优先缩略图、分页 next、html 简介、alternate/related 不算导航。
local CALIBRE_BOOKS = [=[<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom" xmlns:dc="http://purl.org/dc/terms/" xmlns:opds="http://opds-spec.org/2010/catalog">
  <title>Recently added Books</title>
  <link rel="next" title="Next" href="/opds/new?offset=60" type="application/atom+xml;profile=opds-catalog;type=feed;kind=navigation"/>
  <entry>
    <title>三体</title>
    <id>urn:uuid:5b7a8e7e-1111</id>
    <author><name>刘慈欣</name></author>
    <author><name>Ken Liu</name></author>
    <dc:language>zh</dc:language>
    <category scheme="http://www.bisg.org/standards/bisac_subject/index.html" term="科幻" label="科幻"/>
    <category term="小说"/>
    <summary type="html">&lt;p&gt;地球往事&lt;/p&gt; &lt;b&gt;三部曲&lt;/b&gt;</summary>
    <link type="image/jpeg" href="/opds/cover/12" rel="http://opds-spec.org/image"/>
    <link type="image/jpeg" href="/opds/cover_240_240/12" rel="http://opds-spec.org/image/thumbnail"/>
    <link rel="alternate" type="application/atom+xml;type=entry;profile=opds-catalog" href="/opds/book/12"/>
    <link rel="related" type="application/atom+xml;profile=opds-catalog" href="/opds/author/3"/>
    <link rel="http://opds-spec.org/acquisition" href="/opds/download/12/pdf/" length="9000" type="application/pdf"/>
    <link rel="http://opds-spec.org/acquisition" href="/opds/download/12/epub/" length="1234" type="application/epub+zip"/>
    <link rel="http://opds-spec.org/acquisition" href="/opds/download/12/kepub/" type="application/kepub+zip"/>
    <link rel="http://opds-spec.org/acquisition/buy" href="https://shop.example/12" type="text/html"/>
  </entry>
  <entry>
    <title><![CDATA[Only RAR]]></title>
    <id>urn:uuid:rar</id>
    <link rel="http://opds-spec.org/acquisition" href="/opds/download/13/cbr/" type="application/x-cbr"/>
  </entry>
</feed>]=]

feed = Mapper.feed(CALIBRE_BOOKS, "http://nas:8083/opds/new")
Assert.eq(feed.next, "http://nas:8083/opds/new?offset=60")
Assert.len(feed.items, 2)
local book = feed.items[1]
Assert.eq(book.source_id, "opds")
Assert.eq(book.stable_id, "urn:uuid:5b7a8e7e-1111")
Assert.eq(book.title, "三体")
Assert.eq(book.authors, "刘慈欣, Ken Liu")
Assert.eq(book.category, "科幻,小说")
Assert.eq(book.intro, "地球往事 三部曲")
Assert.eq(book.cover_url, "http://nas:8083/opds/cover_240_240/12")
Assert.eq(book.download, "http://nas:8083/opds/download/12/epub/")
Assert.eq(book.format, "epub")
Assert.eq(book.filesize, 1234)
Assert.is_nil(book.feed)
-- 只有本地书库打不开的格式：仍是书（可看详情），但没有下载目标。
Assert.eq(feed.items[2].title, "Only RAR")
Assert.eq(feed.items[2].stable_id, "urn:uuid:rar")
Assert.is_nil(feed.items[2].download)
Assert.is_nil(feed.items[2].format)

-- Komga：命名空间前缀、泛型 application/zip 靠 href 后缀认格式、无 id 时用下载地址当身份、单引号属性。
local KOMGA = [[<?xml version="1.0" encoding="UTF-8"?>
<atom:feed xmlns:atom="http://www.w3.org/2005/Atom">
  <atom:title>Series</atom:title>
  <atom:entry>
    <atom:title>Vol. 1</atom:title>
    <atom:link rel="http://opds-spec.org/acquisition" type="application/zip" href="books/0A1/file/Vol%201.CBZ"/>
    <atom:link rel='http://opds-spec.org/image/thumbnail' type='image/jpeg' href='books/0A1/thumbnail'/>
    <atom:link rel="http://vaemendis.net/opds-pse/stream" type="image/jpeg" href="books/0A1/pages/{pageNumber}"/>
  </atom:entry>
  <atom:entry>
    <atom:title>Unknown</atom:title>
    <atom:link rel="http://opds-spec.org/acquisition" type="application/octet-stream" href="books/0A2/file"/>
  </atom:entry>
</atom:feed>]]

feed = Mapper.feed(KOMGA, "https://komga.example/opds/v1.2/series/9")
Assert.eq(feed.title, "Series")
-- 第二条既无 id 又无可用格式，没有身份可言，丢弃。
Assert.len(feed.items, 1)
Assert.eq(feed.items[1].format, "cbz")
Assert.eq(feed.items[1].download, "https://komga.example/opds/v1.2/series/books/0A1/file/Vol%201.CBZ")
Assert.eq(feed.items[1].stable_id, feed.items[1].download)
Assert.eq(feed.items[1].cover_url, "https://komga.example/opds/v1.2/series/books/0A1/thumbnail")

-- COPS：相对 php 地址 + open-access 获取 + xhtml 内容。
local COPS = [[<feed xmlns="http://www.w3.org/2005/Atom">
<title>COPS</title>
<entry>
  <title>Dune</title>
  <id>urn:uuid:dune</id>
  <content type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml"><p>Arrakis &amp; spice</p></div></content>
  <link rel="http://opds-spec.org/acquisition/open-access" type="application/x-mobipocket-ebook" href="fetch.php?data=1&amp;type=mobi"/>
</entry>
</feed>]]
feed = Mapper.feed(COPS, "http://cops.example/cops/feed.php?page=3")
Assert.eq(feed.items[1].intro, "Arrakis & spice")
Assert.eq(feed.items[1].format, "mobi")
Assert.eq(feed.items[1].download, "http://cops.example/cops/fetch.php?data=1&type=mobi")

-- 不是目录：HTML 登录页 / 截断 JSON / 非 OPDS 的 JSON。
local none, err = Mapper.feed("<!DOCTYPE html><html><body>login</body></html>", "http://x/")
Assert.is_nil(none)
Assert.eq(err, "不是有效的 OPDS 目录")
none, err = Mapper.feed('{"metadata": {', "http://x/")
Assert.is_nil(none)
Assert.eq(err, "不是有效的 OPDS 目录")
Assert.is_nil((Mapper.feed('{"error":"unauthorized"}', "http://x/")))
Assert.is_nil((Mapper.feed(nil, "http://x/")))
feed = Mapper.feed("<feed></feed>", "http://x/")
Assert.len(feed.items, 0)

-- OPDS 2.0 根：navigation 平铺；有 self 的 group 折叠成导航项，无 self 的 group 内容平铺；templated 搜索。
local V2_ROOT = [[{
  "metadata": { "title": "Example 2.0" },
  "links": [
    { "rel": "self", "href": "/opds2", "type": "application/opds+json" },
    { "rel": "search", "href": "/opds2/search{?query,title,author}", "type": "application/opds+json", "templated": true },
    { "rel": ["next"], "href": "/opds2?page=2", "type": "application/opds+json" }
  ],
  "navigation": [
    { "href": "/opds2/new", "title": "New Publications", "type": "application/opds+json", "rel": "current" },
    { "href": "no-title", "type": "application/opds+json" }
  ],
  "groups": [
    { "metadata": { "title": "Popular" },
      "links": [ { "rel": "self", "href": "/opds2/popular", "type": "application/opds+json" } ],
      "publications": [ { "metadata": { "title": "hidden" }, "links": [] } ] },
    { "metadata": { "title": "Genres" },
      "navigation": [ { "href": "/opds2/sf", "title": "Science Fiction", "type": "application/opds+json" } ] }
  ]
}]]
feed = Mapper.feed(V2_ROOT, "https://lib.example/opds2")
Assert.eq(feed.title, "Example 2.0")
Assert.len(feed.items, 4)
Assert.eq(feed.items[1].title, "New Publications")
Assert.eq(feed.items[1].feed, "https://lib.example/opds2/new")
Assert.eq(feed.items[2].title, "未知书名")
Assert.eq(feed.items[3].title, "Popular")
Assert.eq(feed.items[3].feed, "https://lib.example/opds2/popular")
Assert.eq(feed.items[4].feed, "https://lib.example/opds2/sf")
Assert.eq(feed.next, "https://lib.example/opds2?page=2")
Assert.eq(feed.search_template, "https://lib.example/opds2/search{?query,title,author}")
Assert.is_nil(feed.search_osd)
Assert.eq(Mapper.searchUrl(feed.search_template, "a b"), "https://lib.example/opds2/search?query=a%20b")
Assert.eq(Mapper.searchUrl("/s?x=1{&query}", "q"), "/s?x=1&query=q")
Assert.eq(Mapper.searchUrl("/s/{query}{?page}", "q"), "/s/q")

-- OPDS 2.0 publication：本地化标题、混合 author/subject、多格式择优、LCP 间接获取忽略、最窄封面。
local V2_PUBS = [[{
  "metadata": { "title": "Books" },
  "publications": [
    { "metadata": {
        "identifier": "urn:isbn:978031600000X",
        "title": { "fr": "Moby-Dick FR", "en": "Moby-Dick" },
        "author": [ "Herman Melville", { "name": { "en": "Ishmael" } } ],
        "subject": [ { "name": "Sea" }, "Classic" ],
        "description": "<p>Call me &lt;Ishmael&gt;.</p>" },
      "links": [
        { "rel": "http://opds-spec.org/acquisition", "href": "/dl/1.pdf", "type": "application/pdf" },
        { "rel": "http://opds-spec.org/acquisition/buy", "href": "/lcp/1", "type": "application/vnd.readium.lcp.license.v1.0+json",
          "properties": { "indirectAcquisition": [ { "type": "application/epub+zip" } ] } },
        { "rel": ["http://opds-spec.org/acquisition/open-access"], "href": "/dl/1.epub", "type": "application/epub+zip",
          "properties": { "size": 2048 } }
      ],
      "images": [
        { "href": "/img/1-big.jpg", "type": "image/jpeg", "width": 1400 },
        { "href": "/img/1-small.jpg", "type": "image/jpeg", "width": 120 },
        { "href": "/img/1-mid.jpg", "type": "image/jpeg", "width": 400 }
      ] },
    { "metadata": { "title": "No id, no format" },
      "links": [ { "rel": "http://opds-spec.org/acquisition", "href": "/dl/2", "type": "application/octet-stream" } ] },
    { "metadata": { "title": "Unsupported", "identifier": "urn:x:3", "author": "Solo" },
      "links": [ { "rel": "http://opds-spec.org/acquisition", "href": "/dl/3.cbr", "type": "application/x-cbr" } ] }
  ]
}]]
feed = Mapper.feed(V2_PUBS, "https://lib.example/opds2/new")
Assert.len(feed.items, 2)
book = feed.items[1]
Assert.eq(book.source_id, "opds")
Assert.eq(book.stable_id, "urn:isbn:978031600000X")
Assert.eq(book.title, "Moby-Dick")
Assert.eq(book.authors, "Herman Melville, Ishmael")
Assert.eq(book.category, "Sea,Classic")
Assert.eq(book.intro, "Call me .")
Assert.eq(book.download, "https://lib.example/dl/1.epub")
Assert.eq(book.format, "epub")
Assert.eq(book.filesize, 2048)
Assert.eq(book.cover_url, "https://lib.example/img/1-small.jpg")
Assert.eq(feed.items[2].stable_id, "urn:x:3")
Assert.eq(feed.items[2].authors, "Solo")
Assert.is_nil(feed.items[2].download)

-- OpenSearch 描述：优先 Atom 结果模板，否则退回任一模板。
local OSD = [[<?xml version="1.0"?>
<OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
  <Url type="text/html" template="/web/search?q={searchTerms}"/>
  <Url type="application/atom+xml" template="/opds/search?query={searchTerms}&amp;start={startPage?}"/>
</OpenSearchDescription>]]
local template = Mapper.searchTemplate(OSD, "http://nas:8083/opds/osd")
Assert.eq(template, "http://nas:8083/opds/search?query={searchTerms}&start={startPage?}")
Assert.eq(Mapper.searchTemplate('<OpenSearchDescription><Url template="s?q={searchTerms}"/></OpenSearchDescription>',
    "http://h/opds/osd"), "http://h/opds/s?q={searchTerms}")
Assert.is_nil(Mapper.searchTemplate("<OpenSearchDescription/>", "http://h/"))
Assert.eq(Mapper.searchUrl(template, "三体 %"), "http://nas:8083/opds/search?query=%E4%B8%89%E4%BD%93%20%25&start=")
