--[[--
source.wechat notes/annotations/mapper 离线用例

@module tests.source.wechat.sync_spec
--]]

local Assert = require("support.assert")

package.loaded["source.wechat.mapper"] = nil
package.loaded["source.wechat.notes"] = nil
package.loaded["source.wechat.annotations"] = nil

local Mapper = require("source.wechat.mapper")
local Notes = require("source.wechat.notes")
local Annotations = require("source.wechat.annotations")

do
    local rows = Mapper.shelfProgressRows({
        bookProgress = {
            { bookId = "1", progress = 40, chapterUid = "u1" },
        },
    })
    Assert.eq(#rows, 1)
    Assert.eq(rows[1].stable_id, "1")
    Assert.eq(rows[1].fraction, 0.4)
    Assert.eq(rows[1].chapter_uid, "u1")
end

do
    local anns = Notes.toAnnotations({
        updated = {
            {
                chapterUid = "9",
                markText = "hello",
                range = "0-5",
                createTime = 100,
            },
        },
    }, "9", {
        reviews = {
            { review = { range = "0-5", content = "想法", reviewId = "rv1" } },
            { review = { content = "整本书评，无 range" } },
        },
    })
    Assert.eq(#anns, 1)
    Assert.eq(anns[1].text, "hello")
    Assert.eq(anns[1].note, "想法")
    Assert.eq(anns[1].wr_review_id, "rv1")
end

do
    -- 真实 /book/bookmarklist 回包：markText 明文、chapterIdx 只在 chapters 里
    local anns = Notes.toAnnotations({
        synckey = 1787872819,
        updated = {
            {
                bookId = "820954",
                chapterUid = 4,
                bookmarkId = "820954_4_303-332",
                type = 1,
                createTime = 1601272592,
                range = "303-332",
                markText = "“当然不是！”几乎是下意识的，牧云开口回应道。",
            },
        },
        chapters = { { title = "课堂解答", chapterUid = 4, chapterIdx = 4 } },
    }, nil, nil, "wechat", "820954")
    Assert.eq(#anns, 1)
    Assert.eq(anns[1].chapter_idx, 4)
    Assert.eq(anns[1].wr_range, "303-332")
    Assert.eq(anns[1].wr_bookmark_id, "820954_4_303-332")
    Assert.eq(anns[1].text, "“当然不是！”几乎是下意识的，牧云开口回应道。")
    Assert.eq(anns[1].note, "")
end

do
    local wire = {
        updated = {
            { chapterUid = "9", markText = "hello", range = "0-5", createTime = 100, type = 1 },
            { chapterUid = "9", markText = "skip", range = "1-2", createTime = 101, type = 0 },
        },
        items = {
            { chapterUid = "9", markText = "popular", range = "2-5", userVid = "999" },
        },
    }
    Assert.eq(#Notes.toAnnotations(wire, "9"), 1)
    Assert.eq(#Notes.toAnnotations({ items = wire.items }, "9"), 0)
    Assert.eq(Notes.toAnnotations({
        updated = {
            { chapterUid = "8", chapterIdx = 8, markText = "x", range = "0-1", type = 1, createTime = 1 },
        },
    }, nil, nil, "wechat", "1")[1].chapter_idx, 8)
    Assert.eq(Notes.toAnnotations({
        chapters = { { chapterUid = "9", chapterIdx = 9 } },
        updated = {
            { chapterUid = "9", markText = "x", range = "0-1", type = 1, createTime = 1 },
        },
    }, nil, nil, "wechat", "1")[1].chapter_idx, 9)
end

do
    -- 章节壳：<h1> 不占 p 编号；段首缩进折叠为 1 空格，故 p[2] 从 offset 1 起。
    -- 期望值取自 KOReader 自己写出的 xpointer（pos1 是半开上界）。
    local shell = table.concat({
        "<html><head><title>指婚</title></head><body><h1>指婚</h1>",
        "<p>莫问毕竟是六星炼丹师。</p>\n",
        "<p>    要是牧钱反应过来。</p>\n",
        "<p>重复段落文本。</p>\n",
        "<p>重复段落文本。</p>",
        "</body></html>",
    })
    Assert.eq(#Annotations.paragraphs(shell), 4)

    local pos0, pos1 = Annotations.locate(shell, "莫问毕竟是六星炼丹师。")
    Assert.eq(pos0, "/html/body/p[1]/text().0")
    Assert.eq(pos1, "/html/body/p[1]/text().11")

    pos0, pos1 = Annotations.locate(shell, "要是牧钱反应过来。")
    Assert.eq(pos0, "/html/body/p[2]/text().1")
    Assert.eq(pos1, "/html/body/p[2]/text().10")

    -- markText 带换行/多空格时按 crengine 规则折叠后再比
    Assert.eq(Annotations.locate(shell, "  莫问毕竟是六星炼丹师。\n"), "/html/body/p[1]/text().0")

    -- 文本重复出现时 range 决定落在哪一段
    Assert.eq(Annotations.locate(shell, "重复段落文本。"), "/html/body/p[3]/text().0")
    local runes = #Annotations.plainBodyRunes(shell)
    Assert.is_true(runes > 0)
    Assert.eq(Annotations.locate(shell, "重复段落文本。", "34-41"), "/html/body/p[4]/text().0")

    Assert.is_nil(Annotations.locate(shell, "正文里不存在的句子"))
    Assert.is_nil(Annotations.locate(shell, ""))
end

do
    -- 跨段划线：微信 markText 直接跨 <p> 边界，段首缩进与段间换行都不在其中
    local shell = table.concat({
        "<html><body><h1>课堂解答</h1>",
        '<p>    “当然不是！”</p>\n',
        "<p>    几乎是下意识的，牧云开口回应道。</p>",
        "</body></html>",
    })
    local pos0, pos1 = Annotations.locate(shell, "“当然不是！”几乎是下意识的，牧云开口回应道。")
    Assert.eq(pos0, "/html/body/p[1]/text().1")
    Assert.eq(pos1, "/html/body/p[2]/text().17")

    -- 单段仍按原样定位，不受跨段流影响
    Assert.eq(Annotations.locate(shell, "牧云开口回应道。"), "/html/body/p[2]/text().9")
end

do
    -- 定位失败的远端划线不能进 doc_settings：drawSavedHighlight 会解 pos0 并抛错
    local localized = Notes.localizeAnnotations(nil, {
        { drawer = "lighten", text = "找不到的原文", wr_range = "0-6" },
    }, nil)
    Assert.eq(#localized, 1)
    Assert.is_nil(localized[1].pos0)
end

do
    -- range 是原始 HTML 索引（含标签），不能按可见文本切片。旧实现先用 textAtRange
    -- 把 "0-4" 当成可见文本偏移切成 "AAAA"，导致划线定位被错误覆盖。
    local html = '<html><head><title>t</title></head><body><h1>t</h1>'
        .. '<p><span class="x">AAAA</span>作者：罗贯<span>BBBB</span></p>'
        .. '</body></html>'
    local path = os.tmpname()
    local f = assert(io.open(path, "wb")); f:write(html); f:close()
    local localized = Notes.localizeAnnotations(nil, {
        { drawer = "lighten", text = "作者：罗贯", wr_range = "0-4" },
    }, path)
    os.remove(path)
    Assert.eq(#localized, 1)
    Assert.eq(localized[1].pos0, "/html/body/p[1]/text().4")
    Assert.eq(localized[1].pos1, "/html/body/p[1]/text().9")
end

do
    Assert.eq(Notes.decodeMarkText("5L2c6ICF77ya572X6LSv"), "作者：罗贯")
    Assert.eq(require("utils.text").base64Encode("作者：罗贯"), "5L2c6ICF77ya572X6LSv")
    Assert.eq(Annotations.findRange("0123456789", "234"), "2-5")
    local html = '<body><h1>指婚</h1><p>莫问毕竟是六星炼丹师</p></body>'
    Assert.eq(Annotations.findRange(html, "莫问毕"), "0-3")
    local body = Notes.toBookmarkBody("1", 9, 2, 395275575, {
        text = "hello",
        drawer = "lighten",
        wr_range = "0-5",
    })
    Assert.eq(body.bookId, "1")
    Assert.eq(body.chapterUid, 9)
    Assert.eq(body.bookVersion, 395275575)
    Assert.eq(body.range, "0-5")
    Assert.eq(body.markText, require("utils.text").base64Encode("hello"))
    Assert.eq(#Notes.pushCandidates({
        { drawer = "lighten", text = "a" },
        { drawer = "lighten", text = "b", wr_bookmark_id = 1 },
    }), 1)
    Assert.eq(#Notes.notePushCandidates({
        { note = "想法", wr_range = "0-1", wr_bookmark_id = "bm1" },
        { note = "无划线", wr_range = "0-1" },
    }), 1)
    local review_body = Notes.toReviewBody("1", 9, {
        note = "想法",
        text = "原文",
        wr_range = "0-5",
    })
    Assert.eq(review_body.bookId, "1")
    Assert.eq(review_body.content, "想法")
    Assert.eq(review_body.abstract, "原文")
    Assert.eq(review_body.range, "0-5")
    Assert.eq(review_body.chapterUid, 9)
    local version = Mapper.bookVersion({ book = { version = 123 } })
    Assert.eq(version, 123)
end

do
    local function assertStripped(input, needle)
        local stripped = Annotations.stripInjected(input)
        Assert.is_true(stripped:find("wr%-underline", 1) == nil, input)
        if needle then
            Assert.is_true(stripped:find(needle, 1, true) ~= nil, input)
        end
    end
    assertStripped('<p><span class="wr-underline">ab</span></p>', "ab")
    assertStripped('<p><span class="content wr-underline hot">x</span></p>', "x")
    assertStripped("<p><span class='wr-underline'>y</span></p>", "y")
    assertStripped('<p><span class="wr-underline" data-id="1">z</span></p>', "z")
    assertStripped('<p>a<span class="wr-underline">b</span>c<span class="wr-underline">d</span></p>', "abcd")
    Assert.eq(Annotations.cleanChapterHtml('<title>第六章</title><p>正文</p>'), "<p>正文</p>")
    Assert.eq(Annotations.cleanChapterHtml('<title>第六章</title>\n<p>正文</p>'), "<p>正文</p>")
end
