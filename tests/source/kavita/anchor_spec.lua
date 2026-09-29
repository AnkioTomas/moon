local Assert = require("support.assert")

local entries = {}
package.preload["ffi/archiver"] = function()
    return {
        Reader = {
            new = function()
                return {
                    open = function() return true end,
                    close = function() end,
                    extractToMemory = function(_, key) return entries[key] end,
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
        "<html><body><p>Alpha paragraph one.</p>"
        .. "<p>Beta paragraph two with footnote[1].</p></body></html>",
    ["OPS/sub/chapter2.xhtml"] =
        "<html><body><section><p>Nested gamma.</p></section><p>Delta flat.</p></body></html>",
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
