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
    local html = '<span> 【言情排行】 </span><div><ul><li><a href="/book2/1" class="track" data-x=\'{"a":1}\'>甲&amp;乙</a></li></ul></div>'
        .. '<span>【纯爱排行】</span><ul><li><a href="/book2/2">丙</a></li><li><a href="/book2/3">丁</a></li></ul>'
    local sections = Mapper.rankSections(html)
    Assert.len(sections, 2)
    Assert.eq(sections[1].title, "言情排行")
    Assert.eq(sections[1].books[1].stable_id, "1")
    Assert.eq(sections[1].books[1].title, "甲&乙")
    Assert.len(sections[2].books, 2)
    Assert.len(Mapper.rankSections("<html></html>"), 0)
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
        { chapterid = "3", chaptertype = "0", chaptername = "第三章", islock = "0", isvip = 2 },
    } })
    Assert.len(toc, 2)
    Assert.eq(toc[2].uid, "3")
    Assert.eq(toc[2].idx, 2)
    Assert.is_true(toc[2].vip)
    Assert.is_nil(toc[1].vip)
    Assert.eq(toc[1].toc_version, Mapper.TOC_VERSION)
end

do
    Assert.eq(Mapper.webContent('<ul class="content_ul"><li class="x">甲<br>乙&amp;丙</li></ul>'), "甲\n乙&丙")
    Assert.is_nil(Mapper.webContent("<h1>提示</h1>"))
    Assert.eq(Mapper.webContent('<ul class="content_ul"><li>甲<script>var a = "x";</script>乙</li></ul>'), "甲乙")
    local vip = '<ul class="content_ul"><li><div id="content_1">vip内容加载中...</div><div id="contentvars">'
        .. '<input type="hidden" name="novelid" value="9942287"><input type="hidden" name="chapterid" value="23">'
        .. '<input type="hidden" name="readerid" value="85927522"><input type="hidden" name="accessKey" value="PxowDj">'
        .. '<input type="hidden" name="cryptInfo" value="UahebT8I2W5DVP5RtJTyCv1C6busic0hCivj23MPTk2HT99HFI3DvvCodX1QFhgRjU3iX1mxo8d2Gew/rq0qmDncXWCcbF7pIJ8MOhTRzV8=">'
        .. '<input type="hidden" name="content" value="Emlwl6ggvu2rApuyRLY0AEkcBQrKkbdlc4dnnXiyv2GlVkdadO7XU7ajVLp7r4yNKJsCzyUFsnFXtjXtpHOMCMWh7YMzOwF/YC/3uid37ZFyJcrWtkoot1B5mGTJYe5s0Vdy+pJl3IwBMXuHFH88vVgUfiXj+mxoaeYo/Znglqk="></div></li></ul>'
    Assert.eq(Mapper.webContent(vip), "　　甲&乙\n\n　　丙\238\129\132丁")
    Assert.is_nil(Mapper.webContent(vip:gsub("PxowDj", "xxxxxx")))
end

do
    -- key / iv 取摘要里任意偏移的窗口，正文也可能是未编码的 UTF-8。
    local Aes, Md5, Text = require("crypto.aes"), require("crypto.md5"), require("utils.text")
    local function enc(plain, source, key_off, iv_off)
        local d = Md5.hex(source)
        d = d .. d
        return Text.base64Encode(Aes.cbc_encrypt(plain, d:sub(key_off + 1, key_off + 16), d:sub(iv_off + 1, iv_off + 16)))
    end
    local meta = Text.base64Encode('{"time":1792544104,"key":"HqgOwYk","ver":"20250926"}')
    local body = "　　沈玄宁讪讪一笑，道：“我是路过的。”<br><br>　　他转身走了，留下一句话：好自为之。"
    local page = '<div id="contentvars"><input name="novelid" value="9942287"><input name="chapterid" value="23">'
        .. '<input name="readerid" value="85927522"><input name="accessKey" value="AcsRWK">'
        .. '<input name="cryptInfo" value="' .. enc(meta, "9942287.23.85927522.AcsRWK", 27, 11) .. '">'
        .. '<input name="content" value="' .. enc(body, "HqgOwYk179254410485927522", 12, 28) .. '"></div>'
    Assert.eq(require("source.jjwxc.vip").content(page), body)
end

do
    package.loaded["source.jjwxc.font"] = nil
    local Font = require("source.jjwxc.font")
    local fh = assert(io.open("tests/fixtures/jjwxcfont_9eo8b.ttf", "rb"))
    local ttf = fh:read("*a")
    fh:close()
    local map = Font.mapping(ttf)
    local n = 0
    for _code in pairs(map) do n = n + 1 end
    Assert.eq(n, 200)
    Assert.eq(map[0xE044], "他")
    Assert.eq(map[0xE9BE], "已")
    -- 私有区字 → 真字；字后的零宽占位去掉；未命中的私有区字原样保留。
    Assert.eq(Font.decode("\u{E044}\u{200B}说\u{E9BE}\u{FEFF}\u{F8F0}", map), "他说已\u{F8F0}")
    Assert.is_nil(Font.mapping("not a font"))
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
