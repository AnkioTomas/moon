--[[--
source.rss.xml / xml_handler 离线用例：纯 XML 解析、查询与序列化。

@module tests.xml_spec
--]]

local Assert = require("support.assert")
local Xml = require("source.rss.xml")
local Handler = require("source.rss.xml_handler")
local Text = require("utils.text")

-- 实体解码已迁 Text.xmlDecode（详见 tests/utils/text_spec.lua）
do
    Assert.eq(Text.xmlDecode("&lt;a&gt; &amp; &quot;b&quot; &apos;c&apos;"),
        [[<a> & "b" 'c']])
    Assert.eq(Text.xmlDecode("无实体"), "无实体")
end

-- 数字实体（十进制/十六进制）与多码点 UTF-8
do
    Assert.eq(Text.xmlDecode("&#65;"), "A")
    Assert.eq(Text.xmlDecode("&#x41;&#X41;"), "AA")
    Assert.eq(Text.xmlDecode("&#228;"), "\195\164")           -- U+00E4，2 字节
    Assert.eq(Text.xmlDecode("&#x4E2D;"), "\228\184\173")     -- U+4E2D 中，3 字节
    Assert.eq(Text.xmlDecode("&#128512;"), "\240\159\152\128") -- U+1F600，4 字节
end

-- &amp; 最后解码，&amp;lt; 只解一层
do
    Assert.eq(Text.xmlDecode("&amp;lt;"), "&lt;")
    Assert.eq(Text.xmlDecode("&amp;amp;"), "&amp;")
end

-- 容错输入
do
    Assert.eq(Text.xmlDecode(nil), "")
    Assert.eq(Text.xmlDecode("&#x110000;"), "") -- 超出 Unicode 范围的码点
end

-- Xml.parse：空输入与非字符串
do
    local node, err = Xml.parse("")
    Assert.is_nil(node)
    Assert.matches(err, "empty XML")
    node, err = Xml.parse(nil)
    Assert.is_nil(node)
    Assert.matches(err, "empty XML")
end

-- Xml.parse：嵌套、属性、文本、BOM
do
    local root, err = Xml.parse(
        '\239\187\191<a HREF="x&amp;y">t1<b id="1">in</b>t2</a>')
    Assert.is_nil(err)
    Assert.eq(root.name, "#document")
    Assert.len(root.children, 1)
    local a = root.children[1]
    Assert.eq(a.name, "a")
    Assert.eq(a.attr.href, "x&y") -- 属性名小写化、值实体解码
    Assert.len(a.children, 3)
    Assert.eq(a.children[1], "t1")
    Assert.eq(a.children[2].name, "b")
    Assert.eq(a.children[2].attr.id, "1")
    Assert.eq(a.children[2].children[1], "in")
    Assert.eq(a.children[3], "t2")
end

-- Xml.parse：自闭合标签与大小写不敏感配对
do
    local root = Xml.parse("<DIV><br/><img src='a.jpg' /></div>")
    local div = root.children[1]
    Assert.eq(div.name, "div")
    Assert.len(div.children, 2)
    Assert.eq(div.children[1].name, "br")
    Assert.len(div.children[1].children, 0)
    Assert.eq(div.children[2].name, "img")
    Assert.eq(div.children[2].attr.src, "a.jpg")
end

-- Xml.parse：引号包裹的属性值内的 > 不截断标签
do
    local root = Xml.parse('<a title="x>y">t</a>')
    local a = root.children[1]
    Assert.eq(a.name, "a")
    Assert.eq(a.attr.title, "x>y")
    Assert.eq(a.children[1], "t")
    -- 单引号同理
    local root2 = Xml.parse("<a title='x>y'>t</a>")
    Assert.eq(root2.children[1].attr.title, "x>y")
end

-- Xml.parse：CDATA 原文保留（不做实体解码），注释/PI/DOCTYPE 跳过
do
    local root = Xml.parse(
        '<?xml version="1.0"?><!DOCTYPE html><!-- c --><d>'
        .. '<![CDATA[<p>&amp;</p>]]>&lt;x&gt;</d>')
    local d = root.children[1]
    Assert.len(d.children, 2)
    Assert.eq(d.children[1], "<p>&amp;</p>")
    Assert.eq(d.children[2], "<x>")
end

-- Xml.parse：各类不完整输入报错
do
    local node, err = Xml.parse("<a><b></a>")
    Assert.is_nil(node)
    Assert.matches(err, "unbalanced tag: a") -- 报错取闭合标签名
    node, err = Xml.parse("</x>")
    Assert.is_nil(node)
    Assert.matches(err, "unbalanced tag")
    node, err = Xml.parse("<a>")
    Assert.is_nil(node)
    Assert.matches(err, "incomplete XML")
    node, err = Xml.parse("<a><![CDATA[abc</a>")
    Assert.is_nil(node)
    Assert.matches(err, "unterminated CDATA")
    node, err = Xml.parse("<a><!-- abc</a>")
    Assert.is_nil(node)
    Assert.matches(err, "unterminated comment")
    node, err = Xml.parse("<a><b</a>")
    Assert.is_nil(node)
    Assert.matches(err, "incomplete XML") -- `<b</a>` 的 `>` 被当作 b 的结束符
    node, err = Xml.parse("<a><b")
    Assert.is_nil(node)
    Assert.matches(err, "unterminated tag")
end

-- Handler.children / child：名称过滤、大小写不敏感、命名空间本地名
do
    local root = Xml.parse(
        '<r><Item id="1"/><item id="2"/><content:encoded>x</content:encoded></r>')
    local r = root.children[1]
    local items = Handler.children(r, "item")
    Assert.len(items, 2)
    Assert.eq(items[1].attr.id, "1")
    Assert.eq(items[2].attr.id, "2")
    local enc = Handler.child(r, "encoded") -- 本地名匹配 content:encoded
    Assert.not_nil(enc)
    Assert.eq(enc.name, "content:encoded")
    Assert.is_nil(Handler.child(r, "missing"))
    Assert.len(Handler.children(nil, "item"), 0)
end

-- Handler.child 取第一个匹配
do
    local root = Xml.parse("<r><i>1</i><i>2</i></r>")
    Assert.eq(Handler.child(root.children[1], "i").children[1], "1")
end

-- Handler.text：递归拼接文本并裁剪首尾空白
do
    local root = Xml.parse("<a>  hello <b>w<i>o</i>rld</b> ! </a>")
    Assert.eq(Handler.text(root.children[1]), "hello world !")
    Assert.eq(Handler.text(nil), "")
    Assert.eq(Handler.text({}), "")
end

-- Handler.innerXml：序列化子节点，属性排序并转义
do
    local root = Xml.parse('<a z="1" m="&amp;&quot;"><b>x</b>tail</a>')
    local a = root.children[1]
    Assert.eq(Handler.innerXml(a),
        '<b>x</b>tail')
    Assert.eq(Handler.innerXml(root),
        '<a m="&amp;&quot;" z="1"><b>x</b>tail</a>')
end

-- Handler.innerXml：容错输入
do
    Assert.eq(Handler.innerXml(nil), "")
    Assert.eq(Handler.innerXml({}), "")
end
