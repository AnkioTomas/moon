local Assert = require("support.assert")

-- 桩模拟真实 archiver：entries 必须先 iterate 扫描一遍，seek/extractToMemory 才找得到。
local entries = {}
local order = {}
package.preload["ffi/archiver"] = function()
    return {
        Reader = {
            new = function()
                local scanned = {}
                local i = 0
                return {
                    open = function() return true end,
                    close = function() end,
                    iterate = function()
                        return function()
                            i = i + 1
                            local key = order[i]
                            if not key then return nil end
                            scanned[key] = true
                            return { path = key, mode = "file" }
                        end
                    end,
                    extractToMemory = function(_, key)
                        if not scanned[key] then return nil end
                        return entries[key]
                    end,
                }
            end,
        },
    }
end

local Anchor = require("source.kavita.anchor")

entries = {
    ["META-INF/container.xml"] =
        '<container><rootfiles><rootfile full-path="OPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
    ["OPS/content.opf"] =
        '<package><manifest><item id="c1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>'
        .. '<item id="c2" href="sub/chapter2.xhtml" media-type="application/xhtml+xml"/></manifest>'
        .. '<spine><itemref idref="c1"/><itemref idref="c2"/></spine></package>',
    ["OPS/chapter1.xhtml"] =
        '<html><body><p id="a1">Alpha paragraph one.</p>'
        .. "<p>Beta paragraph two with footnote[1].</p></body></html>",
    ["OPS/sub/chapter2.xhtml"] =
        '<html><body><section><p id="g1">Nested gamma.</p></section><p>Delta flat.</p></body></html>',
}

order = {
    "META-INF/container.xml",
    "OPS/content.opf",
    "OPS/chapter1.xhtml",
    "OPS/sub/chapter2.xhtml",
}

-- 扁平书：pageNumber = 0-based spine，xPath 直接 p[N]
local flat = Anchor.compute({
    text = "Beta paragraph two with footnote",
    pos0 = "/body/DocFragment[1]/body/p[2]/text().0",
}, "/fake/book.epub")
Assert.not_nil(flat)
Assert.eq(flat.pageNumber, 0)
Assert.eq(flat.xPath, "//body/p[2]")
Assert.eq(flat.endingXPath, "//body/p[2]")

-- 嵌套书：//body + 同名兄弟完整路径
local nested = Anchor.compute({
    text = "Nested gamma",
    pos0 = "/body/DocFragment[2]/body/section/p[1]/text().0",
}, "/fake/book.epub")
Assert.not_nil(nested)
Assert.eq(nested.pageNumber, 1)
Assert.eq(nested.xPath, "//body/section[1]/p[1]")

-- 平级 p 在同名兄弟里的下标
local flat2 = Anchor.compute({
    text = "Delta flat",
    pos0 = "/body/DocFragment[2]/body/p[1]/text().0",
}, "/fake/book.epub")
Assert.not_nil(flat2)
Assert.eq(flat2.xPath, "//body/p[1]")

-- pos0 指错文档：全 spine 搜索兜底
local fallback = Anchor.compute({
    text = "Nested gamma",
    pos0 = "/body/DocFragment[1]/body/p[1]/text().0",
}, "/fake/book.epub")
Assert.not_nil(fallback)
Assert.eq(fallback.pageNumber, 1)

-- 文本匹配失败 → nil
Assert.is_nil(Anchor.compute({
    text = "not in this book at all",
    pos0 = "/body/DocFragment[1]/body/p[1]/text().0",
}, "/fake/book.epub"))

-- 无文本 → nil
Assert.is_nil(Anchor.compute({ text = "", pos0 = "/body/DocFragment[1]/x" }, "/fake/book.epub"))

-- pos0 → 0-based spine
Assert.eq(Anchor.pageNumber("/body/DocFragment[8]/body/section/p[1]/text().0"), 7)
Assert.is_nil(Anchor.pageNumber("garbage"))

-- xpointer → Kavita bookScrollId：无名段补 [1]，丢 text().N
Assert.eq(Anchor.toScrollId("/body/DocFragment[8]/body/section/p[3]/text().0"),
    "//body/section[1]/p[3]")
Assert.eq(Anchor.toScrollId("/body/DocFragment[2]/body/p[1]/text().0"), "//body/p[1]")
Assert.is_nil(Anchor.toScrollId("/body/DocFragment[2]/body"))
Assert.is_nil(Anchor.toScrollId("garbage"))
-- crengine 归一化形态：body/DocFragment 带 [1] 下标、text 段为 text()[1].0。
-- 真机 last_xpointer 就是这种，必须也能解析出 bookScrollId。
Assert.eq(Anchor.toScrollId("/body[1]/DocFragment[4]/body[1]/p[232]/text()[1].0"),
    "//body/p[232]")
Assert.eq(Anchor.toScrollId("/body[1]/DocFragment[8]/body[1]/section[2]/p[3]/text()[1].0"),
    "//body/section[2]/p[3]")
Assert.eq(Anchor.toScrollId("/body[1]/DocFragment[1]/body[1]"), nil)

-- 0-based spine + bookScrollId → KOReader xpointer（[1] 按 crengine 规范省略）
Assert.eq(Anchor.toXPointer(3, "//body/p[1]", 24), "/body/DocFragment[4]/body/p")
Assert.eq(Anchor.toXPointer(3, "//body/section[1]/p[3]", 24),
    "/body/DocFragment[4]/body/section/p[3]")
Assert.eq(Anchor.toXPointer(0, nil, 24), "/body/DocFragment[1]/body")
-- 已读完：Kavita pageNum == pages，定位钳回最后一个 spine
Assert.eq(Anchor.toXPointer(24, nil, 24), "/body/DocFragment[24]/body")
-- 单文档 epub：crengine 的 xpointer 是 DocFragment/body（无下标）
Assert.eq(Anchor.toXPointer(0, nil, 1), "/body/DocFragment/body")
Assert.is_nil(Anchor.toXPointer(nil, nil, 24))

-- Kavita 网页端进度：bookScrollId = id("X") → 用本地 epub 的 spine 文档解析成路径
Assert.eq(Anchor.resolveScrollId("/fake/book.epub", 0, 'id("a1")'), "//body/p[1]")
Assert.eq(Anchor.resolveScrollId("/fake/book.epub", 1, 'id("g1")'), "//body/section[1]/p[1]")
-- 自家上报的形态原样透传
Assert.eq(Anchor.resolveScrollId("/fake/book.epub", 3, "//body/section[1]/p[3]"),
    "//body/section[1]/p[3]")
-- 无文件 / id 不在该 spine / 空值 → nil（调用方退回只看 spine）
Assert.is_nil(Anchor.resolveScrollId(nil, 0, 'id("a1")'))
Assert.is_nil(Anchor.resolveScrollId("/fake/book.epub", 0, 'id("nope")'))
Assert.is_nil(Anchor.resolveScrollId("/fake/book.epub", 0, ""))
Assert.is_nil(Anchor.resolveScrollId("/fake/book.epub", 0, nil))

-- 与 toXPointer 串起来：id 锚点落到 spine 内的具体元素
Assert.eq(Anchor.toXPointer(1, Anchor.resolveScrollId("/fake/book.epub", 1, 'id("g1")'), 24),
    "/body/DocFragment[2]/body/section/p")
