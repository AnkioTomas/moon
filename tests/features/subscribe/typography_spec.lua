--[[-- features.subscribe.typography：正文片段归一与文章文档。 --]]

local Assert = require("support.assert")
require("support.stubs").install()
local T = require("features.subscribe.typography")

local html = T.article("标<题", '<section><h1>小</h1><p></p><p><img src="a.png"></p><p>正文</p></section>', true, "作者")
Assert.matches(html, "^<h1>标&lt;题</h1><p class=\"byline\">作者</p>")
Assert.is_nil(html:find("<section", 1, true), "section 换成 div")
Assert.matches(html, "<h2>小</h2>", "正文 h1 降级")
Assert.is_nil(html:find("<p></p>", 1, true), "空段落去掉")
Assert.not_nil(html:find('<div class="img"><img src="a.png"></div>', 1, true), "独占段落的图片成居中图块")
Assert.is_nil(T.article("t", '<figure><img src="a.png"><figcaption>注</figcaption></figure>', false):find("<img", 1, true),
    "不下图时去掉图片")

local doc = T.document("订阅<名", "<p>x</p>")
Assert.matches(doc, "<title>订阅&lt;名</title>")
Assert.matches(doc, "<style>.-blockquote")
Assert.is_nil(T.CSS:find("font%-family:[^m]"), "不写正文字体，跟随月读字体")
