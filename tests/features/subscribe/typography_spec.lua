--[[-- features.subscribe.typography：正文片段归一与文章文档。 --]]

local Assert = require("support.assert")
require("support.stubs").install()
local T = require("features.subscribe.typography")

local html = T.article("标<题", '<section><h1>小</h1><p></p><p><img src="a.png"></p><p>正文</p></section>', true, "作者")
Assert.matches(html, "^<h1>标&lt;题</h1><p class=\"byline\">作者</p>")
Assert.is_nil(html:find("<section", 1, true), "section 换成 div")
Assert.matches(html, '<h2 id="mh1">小</h2>', "正文 h1 降级并编号")
Assert.is_nil(html:find("<p></p>", 1, true), "空段落去掉")
Assert.not_nil(html:find('<div class="img"><img src="a.png"></div>', 1, true), "独占段落的图片成居中图块")
Assert.is_nil(T.article("t", '<figure><img src="a.png"><figcaption>注</figcaption></figure>', false):find("<img", 1, true),
    "不下图时去掉图片")

local doc = T.document("订阅<名", "<p>x</p>")
Assert.matches(doc, "<title>订阅&lt;名</title>")
Assert.matches(doc, "<style>.-blockquote")
Assert.is_nil(T.CSS:find("font%-family:[^m]"), "不写正文字体，跟随月读字体")

local body = T.article("t", '<h1>一</h1><h3 id="x" class="c">二 <b>粗</b></h3><h4>四</h4><h2>三</h2>', true)
local heads = T.headings(body)
Assert.len(heads, 3)
Assert.eq(heads[1].title, "一")
Assert.eq(heads[1].depth, 2)
Assert.eq(heads[2].title, "二 粗")
Assert.eq(heads[2].depth, 3)
Assert.eq(heads[2].id, "mh2")
Assert.eq(heads[3].id, "mh3")
Assert.len(T.headings("<p>旧缓存</p><h2>无编号</h2>"), 0)
