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
