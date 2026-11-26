--[[--
Legado 进度文件名与 BookProgress JSON。章号比 KOReader 目录小 1。

@module tests.source.local.legado_progress_spec
--]]

local Assert = require("support.assert")
local Json = require("support.json_stub")
package.loaded["json"] = { encode = Json.encode, decode = Json.decode }

local Layout = require("source.local.layout")
local legado = Layout.get("legado")

Assert.eq(legado.progress_filename("Hello World", "Foo"), "Hello%20World_Foo.json")
Assert.eq(legado.progress_filename("A/B", "C:D"), "A_B_C_D.json", "斜杠和冒号先换成下划线")
Assert.eq(legado.progress_filename("100%", ""), "100%25_.json", "空作者仍留下划线")
Assert.eq(legado.progress_filename("书名", "作者"), "书名_作者.json")

local raw = legado.encode_progress({
    updated_at = 1700000200, chapter_idx = 4, fraction = 0.2, chapter_title = "第四章",
    extra = { offset = 12, volume = 0, at_fraction = 0.2 },
}, "书名", "作者")
local body = Json.decode(raw)
Assert.eq(body.name, "书名")
Assert.eq(body.author, "作者")
Assert.eq(body.durChapterIndex, 3, "阅读的章号从 0 起")
Assert.eq(body.durChapterPos, 12)
Assert.eq(body.durChapterTime, 1700000200000)
Assert.eq(body.durChapterTitle, "第四章")

local back = legado:decode(raw)
Assert.eq(back.chapter_idx, 4)
Assert.eq(back.extra.offset, 12)
Assert.eq(back.chapter_title, "第四章")
Assert.eq(back.updated_at, 1700000200)

Assert.eq(Json.decode(legado.encode_progress({
    updated_at = 1, chapter_idx = 1, fraction = 0,
    extra = { offset = 0, at_fraction = 0 },
}, "a", "")).durChapterIndex, 0)

Assert.eq(Json.decode(legado.encode_progress({
    updated_at = 1, fraction = 0, page = 10,
}, "a", "")).durChapterIndex, 9, "固定版式把页码当成从 0 起的章号")
Assert.eq(Json.decode(legado.encode_progress({
    updated_at = 1, fraction = 0, page = 10,
}, "a", "", 4)).durChapterIndex, 9, "页码兜底不加卷首")

Assert.eq(legado.toc_shift({
    "OEBPS/Text/cover.xhtml", "OEBPS/Text/a.xhtml", "OEBPS/Text/b.xhtml",
    "OEBPS/Text/c.xhtml", "OEBPS/Text/ch.xhtml",
}, "OEBPS/Text/ch.xhtml"), 4, "目录前的 html 都算卷首")
Assert.eq(legado.toc_shift({ "OEBPS/cover.jpg", "OEBPS/Text/ch.xhtml" }, "OEBPS/Text/ch.xhtml"), 0)
Assert.eq(legado.toc_shift({ "OEBPS/Text/a.xhtml" }, "OEBPS/Text/missing.xhtml"), 0, "对不上目录不算偏移")

local shifted = Json.decode(legado.encode_progress({
    updated_at = 1, chapter_idx = 53, fraction = 0, chapter_title = "第五十一章",
    extra = { offset = 1184, at_fraction = 0 },
}, "月亮与六便士", "毛姆", 4))
Assert.eq(shifted.durChapterIndex, 56, "卷首 4 页时第 53 项目录写成阅读的 56")
Assert.eq(shifted.durChapterTitle, "第五十一章")
Assert.eq(shifted.durChapterPos, 1184)

Assert.eq(Json.decode(legado.encode_progress({
    updated_at = 1, chapter_idx = 4, fraction = 0.8,
    extra = { offset = 12, at_fraction = 0.2 },
}, "a", "")).durChapterPos, 0, "百分比已经走开的旧偏移不再写回去")

Assert.is_nil(legado:decode("{"))
Assert.eq(legado:decode('{"durChapterIndex":0,"durChapterPos":3,"durChapterTime":5}').chapter_idx, 1)
Assert.eq(Layout.get(nil).id, "moon")
Assert.eq(Layout.get("nope").id, "moon")
