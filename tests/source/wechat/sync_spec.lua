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
    -- 真实行为：直接发表选中文本想法时，bookmarklist 没有同 range 划线。
    local anns = Notes.toAnnotations({
        updated = {
            {
                chapterUid = "41", chapterIdx = 6, bookmarkId = "bm1",
                type = 1, range = "387-390", markText = "许三观", createTime = 1,
            },
        },
    }, "41", {
        reviews = {
            {
                review = {
                    reviewId = "rv1", chapterUid = 41, chapterIdx = 6,
                    range = "425-431", abstract = "拍打着屁股，", content = "冲冲冲",
                },
            },
        },
    })
    Assert.eq(#anns, 2)
    Assert.is_true(anns[2].wr_review_only)
    Assert.eq(anns[2].note, "冲冲冲")

    -- 单条「许三观」重复无法定位；与后面的唯一想法一起按 range 顺序即可锁定章首。
    local shell = "<html><body><h1>第二章</h1><p>许三观坐着，拍打着屁股，尘土就在许三观身上。</p>"
        .. "<p>许三观又站起来。</p></body></html>"
    local path = os.tmpname()
    local file = assert(io.open(path, "wb")); file:write(shell); file:close()
    local localized = Notes.localizeAnnotations(nil, anns, path, {
        {
            wr_bookmark_id = "bm1", drawer = "lighten", text = "许三观",
            page = "/html/body/p[2]/text().0",
            pos0 = "/html/body/p[2]/text().0", pos1 = "/html/body/p[2]/text().3",
        },
    })
    os.remove(path)
    Assert.eq(localized[1].pos0, "/html/body/p[1]/text().0")
    Assert.eq(localized[2].note, "冲冲冲")
    Assert.is_true(type(localized[2].pos0) == "string")
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
                colorStyle = 2,
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
    Assert.is_nil(anns[1].note)
    Assert.eq(anns[1].color, "green")
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

--- 单条划线走 locateBatch，返回 pos0, pos1；定位不到返回 nil。
local function locate(html, text, range)
    local item = { text = text, wr_range = range }
    local hit = Annotations.locateBatch(html, { item })[item]
    if hit then return hit.pos0, hit.pos1 end
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

    local pos0, pos1 = locate(shell, "莫问毕竟是六星炼丹师。")
    Assert.eq(pos0, "/html/body/p[1]/text().0")
    Assert.eq(pos1, "/html/body/p[1]/text().11")

    pos0, pos1 = locate(shell, "要是牧钱反应过来。")
    Assert.eq(pos0, "/html/body/p[2]/text().1")
    Assert.eq(pos1, "/html/body/p[2]/text().10")

    -- markText 带换行/多空格时按 crengine 规则折叠后再比
    Assert.eq(locate(shell, "  莫问毕竟是六星炼丹师。\n"), "/html/body/p[1]/text().0")

    -- wire range 与本地壳不是同一坐标系；重复文本不能靠 range 猜，宁可不画错位置。
    Assert.is_nil(locate(shell, "重复段落文本。"))
    Assert.is_nil(locate(shell, "重复段落文本。", "34-41"))

    Assert.is_nil(locate(shell, "正文里不存在的句子"))
    Assert.is_nil(locate(shell, ""))

    -- 已同步条目即使文本重复，也按 bookmarkId 复用原生坐标并接受远端笔记更新。
    local path = os.tmpname()
    local file = assert(io.open(path, "wb")); file:write(shell); file:close()
    local localized = Notes.localizeAnnotations(nil, {
        { drawer = "lighten", text = "重复段落文本。", note = "远端新想法", wr_bookmark_id = "bm-2" },
    }, path, {
        {
            drawer = "lighten", text = "重复段落文本。", note = "旧想法", wr_bookmark_id = "bm-2",
            page = "/html/body/p[4]/text().0",
            pos0 = "/html/body/p[4]/text().0", pos1 = "/html/body/p[4]/text().7",
        },
    })
    os.remove(path)
    Assert.eq(localized[1].pos0, "/html/body/p[4]/text().0")
    Assert.eq(localized[1].note, "远端新想法")
end

do
    -- 本地图片 URL、章节壳与 wire HTML 不同，range 仍必须落在 wire rune 坐标。
    local wire = "\239\187\191<p>A&amp;B</p>"
        .. '<p><img src="https://remote/a.jpg"/>重复</p><p>重复</p>'
    local shell = "<html><body><h1>标题</h1><p>A&amp;B</p>"
        .. '<p><img src="/tmp/a.jpg"/>重复</p><p>重复</p></body></html>'
    local mapping, flow = Annotations.rangeMapping(wire), Annotations.flow(shell)
    local range, err = Annotations.toWireRange(
        mapping, flow, "重复", "/html/body/p[3]/text().0", "/html/body/p[3]/text().2"
    )
    Assert.is_nil(err)
    Assert.eq(range, "59-61")
    local first = Annotations.toWireRange(
        mapping, flow, "A&B", "/html/body/p[1]/text().0", "/html/body/p[1]/text().3"
    )
    Assert.eq(first, "3-10")
    local ambiguous, ambiguous_err = Annotations.toWireRange(mapping, flow, "重复")
    Assert.is_nil(ambiguous)
    Assert.eq(ambiguous_err, "ambiguous local highlight")
    Assert.eq(Annotations.wireMapping("<p>x</p><style>bad</style><p>y</p>").text, "xy")
end

do
    -- range 基准是完整解码 xhtml：head 与 xml 声明计入偏移，但其中文字不参与匹配。
    local wire = '<?xml version="1.0"?><html><head><title>正文</title></head><body><p>正文</p></body></html>'
    local shell = "<html><body><p>正文</p></body></html>"
    local prefix = wire:sub(1, wire:find("<p>正文", 1, true) + 2)
    local start = select(2, prefix:gsub("[^\128-\191]", ""))
    local range = Annotations.toWireRange(Annotations.rangeMapping(wire, "html"),
        Annotations.flow(shell), "正文", "/html/body/p[1]/text().0", "/html/body/p[1]/text().2")
    Assert.eq(range, string.format("%d-%d", start, start + 2))
end

do
    -- TXT：range 对纯文本逐 rune 计（BOM 不计，"<" 不是标签），与 weread 的 Source.plain 一致。
    local plain = "\239\187\191甲<&乙\n  丙丁"
    local shell = "<html><body>" .. require("utils.text").textToBody(plain:sub(4)) .. "</body></html>"
    local flow = Annotations.flow(shell)
    Assert.eq(Annotations.toWireRange(Annotations.rangeMapping(plain, "txt"), flow,
        "<&", "/html/body/p[1]/text().1", "/html/body/p[1]/text().3"), "1-3")
    Assert.eq(Annotations.toWireRange(Annotations.rangeMapping(plain, "txt"), flow,
        "丙丁", "/html/body/p[2]/text().0", "/html/body/p[2]/text().2"), "7-9")
end

do
    -- KOReader 跨段选区在段间带换行与缩进；微信正文段间也有缩进空白。都必须能定位。
    local wire = "<body><p>  第一段结尾</p>\n<p>  第二段开头</p></body>"
    local shell = "<html><body><p>  第一段结尾</p><p>  第二段开头</p></body></html>"
    local range, err = Annotations.toWireRange(Annotations.rangeMapping(wire), Annotations.flow(shell),
        "结尾\n  第二", "/html/body/p[1]/text().5", "/html/body/p[2]/text().4")
    Assert.is_nil(err)
    local head = wire:find("结尾", 1, true)
    local runes_before = select(2, wire:sub(1, head - 1):gsub("[^\128-\191]", ""))
    Assert.eq(range:match("^(%d+)"), tostring(runes_before))

    -- 起点 xpointer 不在扁平段落坐标里（嵌套 / 内联节点）时靠唯一文本定位，不拿终点去比。
    Assert.eq(Annotations.toWireRange(Annotations.rangeMapping(wire), Annotations.flow(shell),
        "第二段", "/html/body/div/p[9]/span/text().0", "/html/body/div/p[9]/text().3") ~= nil, true)
end

do
    -- crengine 的 p[N] 只数 <p>，<pre>/<param> 不能占段号。
    local paragraphs = Annotations.paragraphs("<body><pre>x</pre><p>a</p><p class='c'>b</p></body>")
    Assert.len(paragraphs, 2)
    Assert.eq(paragraphs[2].runes[1], "b")
end

do
    -- 跨段划线：微信 markText 直接跨 <p> 边界，段首缩进与段间换行都不在其中
    local shell = table.concat({
        "<html><body><h1>课堂解答</h1>",
        '<p>    “当然不是！”</p>\n',
        "<p>    几乎是下意识的，牧云开口回应道。</p>",
        "</body></html>",
    })
    local pos0, pos1 = locate(shell, "“当然不是！”几乎是下意识的，牧云开口回应道。")
    Assert.eq(pos0, "/html/body/p[1]/text().1")
    Assert.eq(pos1, "/html/body/p[2]/text().17")

    -- 单段仍按原样定位，不受跨段流影响
    Assert.eq(locate(shell, "牧云开口回应道。"), "/html/body/p[2]/text().9")
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
        { drawer = "lighten", text = "note", note = "想法" },
        { drawer = "lighten", text = "b", wr_bookmark_id = 1 },
    }), 1)
    Assert.eq(#Notes.notePushCandidates({
        { note = "想法", wr_range = "0-1", wr_bookmark_id = "bm1" },
        { note = "独立想法", wr_range = "2-3", wr_review_only = true },
        { note = "未修改", wr_range = "3-4", wr_review_id = "rv1" },
        { note = "已修改", wr_range = "4-5", wr_review_id = "rv2", wr_update_review = true },
        { note = "无划线", wr_range = "0-1" },
    }), 3)
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
    local pending = {
        text = "原文", note = "想法", wr_range = "0-5", wr_review_only = true,
    }
    local confirmed = Notes.reconcileReviews({ pending }, {
        reviews = { { review = {
            reviewId = "rv-recovered", range = "9-14", abstract = "原文", content = "想法",
        } } },
    })
    Assert.eq(pending.wr_review_id, "rv-recovered")
    Assert.is_true(confirmed[pending])
    local current = Notes.prepareLocalAnnotations({
        {
            datetime = "old", page = "/body/a", drawer = "lighten",
            note = "旧笔记", wr_bookmark_id = "bm1", wr_review_id = "rv1",
        },
        {
            datetime = "old", page = "/body/b", drawer = "lighten",
            wr_bookmark_id = "bm2",
        },
    }, {
        {
            datetime = "new", page = "/body/a", drawer = "lighten",
            wr_bookmark_id = "bm1",
        },
    })
    Assert.is_true(current[1].wr_delete_review)
    Assert.is_true(current[2].wr_deleted)
    Assert.eq(current[2].wr_bookmark_id, "bm2")

    local remote_note = { {
        page = "/body/n", datetime = "r", text = "原文", note = "想法",
        wr_range = "100-102", wr_review_id = "rv1",
    } }
    local local_note = { {
        page = "/body/n", datetime = "l", text = "原文", note = "想法",
        wr_range = "300-302",
    } }
    Assert.len(Notes.mergeAnnotations(remote_note, local_note, false, true), 1)
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
