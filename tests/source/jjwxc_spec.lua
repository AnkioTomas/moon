--[[--
晋江收藏页 / 目录 / 网页正文映射与 Cookie 解析离线用例。

@module tests.source.jjwxc_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")

package.preload["utils.settings"] = function()
    return { getSource = function() return {} end }
end
package.loaded["source.jjwxc.mapper"] = nil
package.loaded["source.jjwxc.setting"] = nil
local Mapper = require("source.jjwxc.mapper")
local Setting = require("source.jjwxc.setting")

do
    local html = '<ul id="favul"><li readingorbookmarktime="1"><a href="/book2/123">书名…</a> - <a href="/wapauthor/9">某作者</a> [删]</li>'
        .. '<li><a href="/book2/456">另一本</a></li></ul>'
    local rows = Mapper.favRows(html)
    Assert.len(rows, 2)
    Assert.eq(rows[1].id, "123")
    Assert.eq(rows[1].author, "某作者")
    Assert.is_nil(Mapper.favRows("<html>请登录</html>"))
end

do
    local books = Mapper.shelfList({
        { id = "1", title = "短…", info = { novelId = 1, novelName = "全名", authorName = "甲", novelSize = "271,300", novelCover = "" } },
        { id = "2", title = "截断", local_book = { stable_id = "2", title = "本地全名" } },
        { id = "3", title = "兜底", author = "乙" },
    })
    Assert.eq(books[1].title, "全名")
    Assert.eq(books[1].meta.words, 271300)
    Assert.is_nil(books[1].cover)
    Assert.eq(books[2].title, "本地全名")
    Assert.eq(books[3].title, "兜底")
end

do
    local toc = Mapper.toc({ chapterlist = {
        { chapterid = "0", chaptertype = "1", chaptername = "卷一", islock = "0" },
        { chapterid = "1", chaptertype = "0", chaptername = "第一章", islock = "0", chaptersize = "100" },
        { chapterid = "2", chaptertype = "0", chaptername = "锁定", islock = "1" },
        { chapterid = "3", chaptertype = "0", chaptername = "第三章", islock = "0" },
    } })
    Assert.len(toc, 2)
    Assert.eq(toc[2].uid, "3")
    Assert.eq(toc[2].idx, 2)
end

do
    Assert.eq(Mapper.webContent('<ul class="content_ul"><li class="x">甲<br>乙&amp;丙</li></ul>'), "甲\n乙&丙")
    Assert.is_nil(Mapper.webContent("<h1>提示</h1>"))
end

do
    Assert.eq(Setting.parseCookie("b=2; a=1;bad name=3; c="), "a=1; b=2")
    Assert.eq(Setting.fromPayload({ cookies = {
        { domain = ".jjwxc.com", name = "sid", value = "v" },
        { domain = "m.jjwxc.com", name = "JJSESS", value = "w" },
        { domain = "evil.com", name = "x", value = "y" },
    } }), "JJSESS=w; sid=v")
end

do
    local html = require("utils.text").chapterHtml("第一章", "　　甲\n\n  　乙〇\n")
    Assert.eq(html, "<h1>第一章</h1>\n<p>甲</p>\n<p>乙〇</p>")
end

do
    local book = Mapper.book({ novelId = 1, novelName = "x", novelCover = "https://i9-static.jjwxc.net/novelimage.php?novelid=1&coverid=2&ver=abc" })
    Assert.eq(book.cover, "https://i9-static.jjwxc.net/novelimage.php?novelid=1&coverid=2")
end

do
    local books = Mapper.search({ items = {
        { novelid = 5, novelname = "甲", authorname = "乙", novelintroshort = "简介" },
    } })
    Assert.len(books, 1)
    Assert.eq(books[1].stable_id, "5")
    Assert.eq(books[1].title, "甲")
    Assert.eq(books[1].authors, "乙")
end
