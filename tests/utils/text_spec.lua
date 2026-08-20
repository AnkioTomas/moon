--[[-- utils.text：trim / 斜杠 / BOM / 换行 / XML 转义解码 / URL 与 form 编码 / 文本段落化 --]]

local Assert = require("support.assert")

local Text = require("utils.text")

-- ── trim / rtrim ─────────────────────────────
do
    Assert.eq(Text.trim("  hello  "), "hello")
    Assert.eq(Text.trim("\t hi \n"), "hi")
    Assert.eq(Text.trim(""), "")
    Assert.eq(Text.trim("   "), "")
    Assert.eq(Text.trim(nil), "")
    Assert.eq(Text.trim(123), "123")
    -- 中间空白不动
    Assert.eq(Text.trim(" a b "), "a b")

    Assert.eq(Text.rtrim("hi  "), "hi")
    Assert.eq(Text.rtrim("  hi"), "  hi")
    Assert.eq(Text.rtrim(nil), "")

    -- stripWhitespace：去除全部空白（含中间）
    Assert.eq(Text.stripWhitespace(" a b\tc\n"), "abc")
    Assert.eq(Text.stripWhitespace("   "), "")
    Assert.eq(Text.stripWhitespace(nil), "")
end

-- ── 斜杠修剪 ─────────────────────────────
do
    Assert.eq(Text.trimSlashes("/a/b/"), "a/b")
    Assert.eq(Text.trimSlashes("//a//"), "a")
    Assert.eq(Text.trimSlashes("a"), "a")
    Assert.eq(Text.trimSlashes("///"), "")
    Assert.eq(Text.trimSlashes(nil), "")

    Assert.eq(Text.rtrimSlashes("a/b/"), "a/b")
    Assert.eq(Text.rtrimSlashes("/a/"), "/a")
    Assert.eq(Text.rtrimSlashes("https://x/"), "https://x")
    Assert.eq(Text.rtrimSlashes(nil), "")
end

-- ── BOM / 换行 ─────────────────────────────
do
    Assert.eq(Text.stripBom("\239\187\191abc"), "abc")
    Assert.eq(Text.stripBom("abc"), "abc")
    Assert.eq(Text.stripBom(nil), "")

    Assert.eq(Text.normalizeNewlines("a\r\nb\rc\nd"), "a\nb\nc\nd")
    Assert.eq(Text.normalizeNewlines(nil), "")

    Assert.is_true(Text.isValidUtf8("hello 中文"))
    Assert.is_true(Text.isValidUtf8("\240\159\152\128"))
    Assert.is_false(Text.isValidUtf8("\255"))
    Assert.is_false(Text.isValidUtf8("\226\130"))

    Assert.eq(Text.truncateUtf8("abcdef", 4), "abcd")
    Assert.eq(Text.truncateUtf8("中文abc", 4), "中")
    Assert.eq(Text.truncateUtf8("中文", 6), "中文")
    Assert.eq(Text.truncateUtf8("中文", 0), "")
end

-- ── xmlEscape / xmlDecode ─────────────────────────────
do
    Assert.eq(Text.xmlEscape([[a<b>"c"&]]), [[a&lt;b&gt;&quot;c&quot;&amp;]])
    Assert.eq(Text.xmlEscape(nil), "")
    Assert.eq(Text.xmlEscape(5), "5")

    Assert.eq(Text.xmlDecode([[a&lt;b&gt;&quot;c&apos;&amp;]]), [[a<b>"c'&]])
    -- 数字实体：十进制与十六进制
    Assert.eq(Text.xmlDecode("&#65;&#x42;"), "AB")
    -- 多字节码点
    Assert.eq(Text.xmlDecode("&#20013;"), "中")
    Assert.eq(Text.xmlDecode("&#x4E2D;"), "中")
    -- 超范围码点 → 空串
    Assert.eq(Text.xmlDecode("&#99999999;"), "")
    -- 未知命名实体原样保留
    Assert.eq(Text.xmlDecode("&nbsp;"), "&nbsp;")
    Assert.eq(Text.xmlDecode(nil), "")
    -- 往返
    Assert.eq(Text.xmlDecode(Text.xmlEscape([[<a x="&">]])), [[<a x="&">]])
end

-- ── urlEncode / urlDecode ─────────────────────────────
do
    Assert.eq(Text.urlEncode("a b&中"), "a%20b%26%E4%B8%AD")
    -- unreserved 不转义
    Assert.eq(Text.urlEncode("Az09-_.~"), "Az09-_.~")
    Assert.eq(Text.urlEncode(42), "42")

    Assert.eq(Text.urlDecode("a%20b%26%E4%B8%AD"), "a b&中")
    -- + → 空格
    Assert.eq(Text.urlDecode("a+b"), "a b")
    Assert.eq(Text.urlDecode("%2F"), "/")
    Assert.is_nil(Text.urlDecode(nil))
    -- 往返
    Assert.eq(Text.urlDecode(Text.urlEncode("x y/z?&=中")), "x y/z?&=中")
end

-- ── formEncode ─────────────────────────────
do
    -- 键排序
    Assert.eq(Text.formEncode({ b = "2", a = "1" }), "a=1&b=2")
    -- 值编码
    Assert.eq(Text.formEncode({ q = "a b" }), "q=a%20b")
    -- 键也编码
    Assert.eq(Text.formEncode({ ["a b"] = 1 }), "a%20b=1")
    -- nil 值跳过
    Assert.eq(Text.formEncode({ a = 1, b = nil }), "a=1")
    Assert.eq(Text.formEncode({}), "")
    Assert.eq(Text.formEncode(nil), "")
end

-- ── looksLikeHtml / textToBody ─────────────────────────────
do
    Assert.is_true(Text.looksLikeHtml("<p>hi</p>"))
    Assert.is_true(Text.looksLikeHtml("<!DOCTYPE html><html>"))
    Assert.is_true(Text.looksLikeHtml("<h1>t</h1>"))
    Assert.is_false(Text.looksLikeHtml("plain line"))
    Assert.is_false(Text.looksLikeHtml(nil))

    Assert.eq(Text.textToBody("hello\nworld"), "<p>hello</p>\n<p>world</p>")
    -- 空行跳过、行尾空白剥除、行首保留、内容转义
    Assert.eq(Text.textToBody("a  \n\n  b<c"), "<p>a</p>\n<p>  b&lt;c</p>")
    -- CRLF 规范化
    Assert.eq(Text.textToBody("a\r\nb"), "<p>a</p>\n<p>b</p>")
    Assert.eq(Text.textToBody(nil), "")
end
