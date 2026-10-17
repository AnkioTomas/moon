--[[-- utils.text：trim / 斜杠 / BOM / 换行 / XML 转义解码 / URL 与 form 编码 / 文本段落化 --]]

local Assert = require("support.assert")
local Config = require("support.config")

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

-- ── absoluteUrl ───────────────────────────────────────
do
    local base = "http://h:8083/opds/new?page=2#top"
    Assert.eq(Text.absoluteUrl(base, "https://x.org/a"), "https://x.org/a")
    Assert.eq(Text.absoluteUrl(base, "//cdn.org/c.jpg"), "http://cdn.org/c.jpg")
    Assert.eq(Text.absoluteUrl("https://ghfast.top/https://github.com/x", "/https://github.com/o/r/a.opml"),
        "https://ghfast.top/https://github.com/o/r/a.opml", "镜像代理路径里的 // 保留")
    Assert.eq(Text.absoluteUrl(base, "/opds/books"), "http://h:8083/opds/books")
    Assert.eq(Text.absoluteUrl(base, "?page=3"), "http://h:8083/opds/new?page=3")
    Assert.eq(Text.absoluteUrl(base, "#x"), "http://h:8083/opds/new?page=2#x")
    Assert.eq(Text.absoluteUrl(base, "cover/1.jpg"), "http://h:8083/opds/cover/1.jpg")
    Assert.eq(Text.absoluteUrl(base, "../feed.php?id=1"), "http://h:8083/feed.php?id=1")
    Assert.eq(Text.absoluteUrl(base, "./a/../b/"), "http://h:8083/opds/b/")
    -- 查询串里的斜杠不能被当成目录
    Assert.eq(Text.absoluteUrl("http://h/feed.php?p=/x/y", "fetch.php"), "http://h/fetch.php")
    Assert.eq(Text.absoluteUrl("http://h", "a"), "http://h/a")
    Assert.is_nil(Text.absoluteUrl(base, ""))
    Assert.is_nil(Text.absoluteUrl(base, nil))
    Assert.is_nil(Text.absoluteUrl("not a url", "a"))
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

-- ── stripHtml ─────────────────────────────
do
    -- 块级标签与原有换行保留为分段，行内空白折叠，空行丢弃
    Assert.eq(Text.stripHtml("<p>你好<br/>世界</p><DIV>!</DIV>"), "你好\n世界\n!")
    Assert.eq(Text.stripHtml("  a  \t b \r\n\n  c  "), "a b\nc")
    Assert.eq(Text.stripHtml("<b>粗</b><i>斜</i>"), "粗 斜")
    -- 实体解码，&nbsp; 视为空格
    Assert.eq(Text.stripHtml("a&amp;b&nbsp;&lt;c&gt;"), "a&b")
    Assert.eq(Text.stripHtml("x &amp;lt; y"), "x &lt; y")
    -- 转义过的 HTML 再剥一层
    Assert.eq(Text.stripHtml("&lt;b&gt;粗&lt;/b&gt;体"), "粗 体")
    Assert.eq(Text.stripHtml("<![CDATA[<i>斜</i>]]>"), "斜")
    -- 注释、script、style 整块丢弃（大小写不敏感）
    Assert.eq(Text.stripHtml("a<!-- x -->b<SCRIPT>alert(1)</script>c<style>p{}</Style>d"), "a b c d")
    Assert.eq(Text.stripHtml(""), "")
    Assert.eq(Text.stripHtml(nil), "")
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

    Assert.is_true(Text.hasRemoteImageSrc('<img src="https://cdn/x.png"/>'))
    Assert.is_true(Text.hasRemoteImageSrc([[<img src="//cdn/x.png"/>]]))
    Assert.is_true(Text.hasRemoteImageSrc([[<img src="https://x/a.png?q=1&amp;w=2"/>]]))
    Assert.is_false(Text.hasRemoteImageSrc('<img src="data:image/png;base64,AAA"/>'))
    Assert.is_false(Text.hasRemoteImageSrc('<img src="images/foo.png"/>'))
    Assert.is_false(Text.hasRemoteImageSrc('<img src="foo.jpg"/>'))
    Assert.is_false(Text.hasRemoteImageSrc("https://cdn/x.png"))
    Assert.is_false(Text.hasRemoteImageSrc(nil))

    local remote_path = Config.dir() .. "/remote-image-boundary.html"
    local file = assert(io.open(remote_path, "wb"))
    file:write(string.rep("x", 64 * 1024 - 2), [[src="https://cdn/x.png">]])
    file:close()
    Assert.is_true(Text.hasRemoteImageSrcInFile(remote_path))
    pcall(os.remove, remote_path)

    local local_path = Config.dir() .. "/local-image-chapter.html"
    file = assert(io.open(local_path, "wb"))
    file:write('<html><body><img src="images/a.png"/></body></html>')
    file:close()
    Assert.eq(Text.hasRemoteImageSrcInFile(local_path), false)
    pcall(os.remove, local_path)

    local empty_path = Config.dir() .. "/empty-chapter.html"
    file = assert(io.open(empty_path, "wb"))
    file:close()
    Assert.is_nil(Text.hasRemoteImageSrcInFile(empty_path))
    pcall(os.remove, empty_path)

    Assert.eq(Text.htmlBodyFragment('<html><head><title>x</title></head><body><p>hi</p></body></html>'), "<p>hi</p>")
    Assert.eq(Text.htmlBodyFragment('<html><body>title</body></html><html><body><p>main</p></body></html>'), "title\n<p>main</p>")
    Assert.eq(Text.htmlBodyFragment('<body class="a"><div>1</div></body>'), "<div>1</div>")
    Assert.eq(Text.htmlBodyFragment([[<?xml version="1.0"?><!DOCTYPE html><p>x</p>]]), "<p>x</p>")
    Assert.eq(Text.htmlBodyFragment(nil), "")

    Assert.eq(Text.textToBody("hello\nworld"), "<p>hello</p>\n<p>world</p>")
    -- 空行跳过、行尾空白剥除、行首保留、内容转义
    Assert.eq(Text.textToBody("a  \n\n  b<c"), "<p>a</p>\n<p>  b&lt;c</p>")
    -- CRLF 规范化
    Assert.eq(Text.textToBody("a\r\nb"), "<p>a</p>\n<p>b</p>")
    Assert.eq(Text.textToBody(nil), "")

    -- stripLineIndent：逐行剥 ASCII 空白 / 全角空格 / NBSP，行中与行尾不动，空行保留
    Assert.eq(Text.stripLineIndent("　　甲　乙\r\n\t 丙 \n\194\160　丁\n\n"), "甲　乙\n丙 \n丁\n\n")
    Assert.eq(Text.stripLineIndent("无缩进"), "无缩进")
    Assert.eq(Text.stripLineIndent("　　"), "")
    Assert.eq(Text.stripLineIndent(""), "")
    Assert.eq(Text.stripLineIndent(nil), "")
end

-- base64 编解码：空串、单字节、双字节、三字节尾、多字节 UTF-8 与 URL-safe 解码
do
    Assert.eq(Text.base64Encode(""), "")
    Assert.eq(Text.base64Encode("A"), "QQ==")
    Assert.eq(Text.base64Encode("ab"), "YWI=")
    Assert.eq(Text.base64Encode("abc"), "YWJj")
    Assert.eq(Text.base64Encode("作者：罗贯"), "5L2c6ICF77ya572X6LSv")

    Assert.eq(Text.base64Decode("QQ=="), "A")
    Assert.eq(Text.base64Decode("YWI="), "ab")
    Assert.eq(Text.base64Decode("YWJj"), "abc")
    Assert.eq(Text.base64Decode("5L2c6ICF77ya572X6LSv"), "作者：罗贯")
    -- URL-safe 字符与缺失填充
    Assert.eq(Text.base64Decode("YWI"), "ab")
end

-- stripEmoji：图形 emoji、ZWJ 序列、肤色、VS16、国旗、键帽去掉；★ 与空白、普通文字不动
Assert.eq(Text.stripEmoji("a \240\159\152\128 b"), "a  b")
Assert.eq(Text.stripEmoji("\240\159\145\168\226\128\141\240\159\145\169\240\159\145\141\240\159\143\189好"), "好")
Assert.eq(Text.stripEmoji("\240\159\135\168\240\159\135\179中1\239\184\143\226\131\163"), "中1")
Assert.eq(Text.stripEmoji("\226\152\133\226\157\164\239\184\143"), "\226\152\133\226\157\164")
Assert.eq(Text.stripEmoji(""), "")
Assert.is_nil(Text.stripEmoji(nil))
