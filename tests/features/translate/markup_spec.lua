--[[-- features.translate.markup：叶子块识别与译文插入。 --]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()

local Markup = require("features.translate.markup")

local function texts(html)
    local out = {}
    for i, block in ipairs(Markup.blocks(html)) do out[i] = block.text end
    return out
end

-- 只取最内层块：外层 div 装着 p 就不是叶子；li 里有 p 时取 p。
Assert.eq(table.concat(texts([[
<body><div class="c"><p>One <b>bold</b> line.</p><p>第二段</p></div>
<ul><li><p>Item</p></li><li>Plain item</li></ul></body>]]), "|"), "One bold line.|第二段|Item|Plain item")

-- 只装文字的 div 是叶子；自闭合块、空块、纯数字/标点不算。
Assert.eq(table.concat(texts("<div>Hello&amp;bye&nbsp;now</div><p/><p>  </p><p>12 - 34!</p><p>x</p>"), "|"),
    "Hello&bye now|x")

-- 命名空间前缀、大写标签、带属性。
Assert.eq(table.concat(texts('<html:P class="a">Upper</html:P><H2 id="t">Title</H2>'), "|"), "Upper|Title")

-- FB2：title 里的 p、诗行 v。
Assert.eq(table.concat(texts("<section><title><p>章一</p></title><poem><stanza><v>Line</v></stanza></poem></section>"), "|"),
    "章一|Line")

-- 块内换行与多余空白折叠成一个空格。
Assert.eq(texts("<p>a\n   b\t c</p>")[1], "a b c")

-- 插入：译文进原块尾部，转义；已是目标语言（译文=原文）或缺译文的不插。
local html = '<body><p class="x">Hello <i>world</i></p><p>Same</p><p>Missing</p></body>'
local out, count = Markup.inject(html, {
    ["Hello world"] = "你好 <世界> & 人",
    ["Same"] = "Same",
})
Assert.eq(count, 1)

-- 源站译文节点整段去掉；原文、换行译文、class 里只是子串的都留着。
local embedded = table.concat({
    '<link href="../wereadstyle/wrtranslation.css" rel="stylesheet" type="text/css"/>',
    '<h1 class="firstTitle">CHAPTER</h1>\n',
    '<h1 class="wr-translation firstTitle">第一章</h1>\n',
    '<p class="content">Mr and Mrs Dursley</p>\n',
    '<p class="wr-translation content">德思礼\n夫妇</p>',
    '<p class="wr-translation-extra">keep</p>',
}, "")
local stripped, bilingual = Markup.splitEmbedded(embedded)
Assert.is_true(Markup.hasEmbedded(embedded))
Assert.is_nil(stripped:find("wrtranslation.css", 1, true))
Assert.is_nil(stripped:find("第一章", 1, true))
Assert.is_true(stripped:find("CHAPTER", 1, true) ~= nil)
Assert.is_true(stripped:find("Mr and Mrs Dursley", 1, true) ~= nil)
Assert.is_true(stripped:find("wr-translation-extra", 1, true) ~= nil)
Assert.is_nil(stripped:find("德思礼", 1, true))
Assert.eq(Markup.stripEmbedded("<p>Hello</p>"), "<p>Hello</p>")
Assert.is_true(bilingual:find('class="moon-tr"', 1, true) ~= nil)
Assert.is_true(bilingual:find("第一章", 1, true) ~= nil)
Assert.is_true(bilingual:find("德思礼\n夫妇", 1, true) ~= nil)
Assert.is_nil(bilingual:find("wr-translation firstTitle", 1, true))
Assert.is_true(bilingual:find("CHAPTER<br/>", 1, true) ~= nil)
Assert.is_true(bilingual:find("Dursley<br/>", 1, true) ~= nil)
Assert.eq(out, '<body><p class="x">Hello <i>world</i><br/><span class="moon-tr" style="display:block">你好 &lt;世界&gt; &amp; 人</span></p>'
    .. "<p>Same</p><p>Missing</p></body>")

-- 原文已是目标语言：Edge 只在句号后补了空格，不算译文。
local same, same_count = Markup.inject("<p>那一年。夏天</p>", { ["那一年。夏天"] = "那一年。 夏天" })
Assert.eq(same_count, 0)
Assert.eq(same, "<p>那一年。夏天</p>")

-- 同一原文出现多次，每处都插。
local twice, n = Markup.inject("<p>A</p><p>A</p>", { A = "甲" })
Assert.eq(n, 2)
Assert.eq(twice, '<p>A<br/><span class="moon-tr" style="display:block">甲</span></p><p>A<br/><span class="moon-tr" style="display:block">甲</span></p>')

-- 没有可插的块：原样返回。
Assert.eq((Markup.inject("<p>A</p>", {})), "<p>A</p>")
Assert.eq((Markup.inject("", { A = "甲" })), "")

-- 译文样式：颜色与字号可单独设置，默认不加。
Assert.eq(Markup.style({ bilingual_color = "", bilingual_scale = 0 }), nil)
local style = Markup.style({ bilingual_color = "#555555", bilingual_scale = 90 })
Assert.eq(style, "color:#555555;font-size:90%")
Assert.eq((Markup.inject("<p>A</p>", { A = "甲" }, style)),
    '<p>A<br/><span class="moon-tr" style="display:block;color:#555555;font-size:90%">甲</span></p>')

-- 目录 nav 里的条目不译，正文照常。
local navdoc = '<nav epub:type="toc"><ol><li><a href="a.xhtml">Chapter</a></li></ol></nav><p>Body</p>'
Assert.eq(#Markup.blocks(navdoc), 1)
Assert.eq((Markup.inject(navdoc, { Chapter = "章", Body = "正文" })),
    '<nav epub:type="toc"><ol><li><a href="a.xhtml">Chapter</a></li></ol></nav><p>Body<br/><span class="moon-tr" style="display:block">正文</span></p>')

-- 默认按段落：一整段一条译文，贴在段尾。
local para = "<p>Mr. Dursley was proud. They were normal.</p>"
Assert.eq(Markup.points("Mr. Dursley was proud. They were normal.", "paragraph")[1].key,
    "Mr. Dursley was proud. They were normal.")
Assert.eq((Markup.inject(para, { ["Mr. Dursley was proud. They were normal."] = "德思礼先生很得意。他们很正常。" })),
    '<p>Mr. Dursley was proud. They were normal.<br/><span class="moon-tr" style="display:block">德思礼先生很得意。他们很正常。</span></p>')

-- 按句子：句号后插入，缩写和小数点不断开；中文句号同样切开。标签中间的句号插在标签外。
local function keys(inner)
    local out = {}
    for i, point in ipairs(Markup.points(inner, "sentence")) do out[i] = point.key end
    return table.concat(out, "|")
end
Assert.eq(keys("Mr. Dursley was proud. They were normal."), "Mr. Dursley was proud.|They were normal.")
Assert.eq(keys("Pi is 3.14. Done."), "Pi is 3.14.|Done.")
Assert.eq(keys("那一年。夏天来了。"), "那一年。|夏天来了。")
Assert.eq(keys("One sentence"), "One sentence")
local sentence_html = '<p>Hello <i>world</i>. Next.</p>'
Assert.eq((Markup.inject(sentence_html, { ["Hello world."] = "你好。", ["Next."] = "下一句。" }, nil, "sentence")),
    '<p>Hello <i>world</i>.<br/><span class="moon-tr" style="display:block">你好。</span> Next.<br/><span class="moon-tr" style="display:block">下一句。</span></p>')
