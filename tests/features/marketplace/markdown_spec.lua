--[[-- features.marketplace.markdown：保守转换，转义 HTML，图片无 src，危险链接不可点。 --]]

local Assert = require("support.assert")
local Markdown = require("features.marketplace.markdown")

Assert.is_nil(Markdown.safeHref("javascript:alert(1)"))
Assert.is_nil(Markdown.safeHref("data:text/html,hi"))
Assert.is_nil(Markdown.safeHref("../secret"))
Assert.is_nil(Markdown.safeHref(""))
Assert.eq(Markdown.safeHref("https://example.com/a"), "https://example.com/a")
Assert.eq(Markdown.safeHref("http://example.com"), "http://example.com")

local html = Markdown.toHtml([[# 标题
这是 **加粗** 和 `code`。

[官网](https://example.com) 和 [坏链](javascript:alert(1))。

![示意图](https://example.com/token.png)

```lua
return "<script>x()</script>"
```

- 一项
- 二项
]])

Assert.is_true(html:find("<h1>标题</h1>", 1, true) ~= nil)
Assert.is_true(html:find("<strong>加粗</strong>", 1, true) ~= nil)
Assert.is_true(html:find("<code>code</code>", 1, true) ~= nil)
Assert.is_true(html:find('href="https://example.com"', 1, true) ~= nil)
Assert.is_nil(html:find("javascript:", 1, true))
Assert.is_true(html:find("坏链", 1, true) ~= nil)
Assert.is_nil(html:find("<img", 1, true))
Assert.is_nil(html:find("token.png", 1, true))
Assert.is_true(html:find("［图片：示意图］", 1, true) ~= nil)
Assert.is_true(html:find("&lt;script&gt;", 1, true) ~= nil)
Assert.is_nil(html:find("<script>", 1, true))
Assert.is_true(html:find("<li>", 1, true) ~= nil)

local empty = Markdown.toHtml("<script>alert(1)</script>")
Assert.is_true(empty:find("&lt;script&gt;", 1, true) ~= nil)
Assert.is_nil(empty:find("<script>", 1, true))


-- 管道表格：对齐、转义单元格、代码与转义管道。
local table_html = Markdown.toHtml([[
| 名称 | 对齐 | 管道 |
| :--- | :---: | ---: |
| 中文 | `code` | a \| b |
| x | y | z |
]])
Assert.is_true(table_html:find("<table", 1, true) ~= nil)
Assert.is_true(table_html:find("<th", 1, true) ~= nil)
Assert.is_true(table_html:find("<td", 1, true) ~= nil)
Assert.is_true(table_html:find("中文", 1, true) ~= nil)
Assert.is_true(table_html:find("<code>code</code>", 1, true) ~= nil)
Assert.is_true(table_html:find("a | b", 1, true) ~= nil)
Assert.is_true(table_html:find('class="md-align-left"', 1, true) ~= nil)
Assert.is_true(table_html:find('class="md-align-center"', 1, true) ~= nil)
Assert.is_true(table_html:find('class="md-align-right"', 1, true) ~= nil)
Assert.is_nil(table_html:find("| 名称 |", 1, true))

-- 原始 HTML：p align、table；脚本仍转义；代码块里的标签保持文本。
local raw = Markdown.toHtml([[
<p align="center"><strong>标题</strong></p>

<table>
<tr><th>A</th><th>B</th></tr>
<tr><td>一</td><td>二</td></tr>
</table>

```
<p>标签应保持文本</p>
<table></table>
```

Also `<p>inline</p>` and &amp; entity outside.

<script>alert(1)</script>
<p onclick="alert(1)" style="color:red" align="center">安全段落</p>
<img src="https://evil.example/a.png" alt="示意图">
]])
Assert.is_true(raw:find('<p align="center"', 1, true) ~= nil)
Assert.is_true(raw:find("md-align-center", 1, true) ~= nil)
Assert.is_true(raw:find("<strong>标题</strong>", 1, true) ~= nil)
Assert.is_true(raw:find("<table", 1, true) ~= nil)
Assert.is_true(raw:find("<th>A</th>", 1, true) ~= nil)
Assert.is_true(raw:find("<td>一</td>", 1, true) ~= nil)
Assert.is_nil(raw:find("<script>", 1, true))
Assert.is_true(raw:find("&lt;script&gt;", 1, true) ~= nil)
Assert.is_nil(raw:find("onclick", 1, true))
Assert.is_nil(raw:find("style=", 1, true))
Assert.is_nil(raw:find("<img", 1, true))
Assert.is_nil(raw:find("evil.example", 1, true))
Assert.is_true(raw:find("［图片：示意图］", 1, true) ~= nil)
Assert.is_true(raw:find("<pre>", 1, true) ~= nil)
Assert.is_true(raw:find("&lt;p&gt;标签应保持文本&lt;/p&gt;", 1, true) ~= nil)
Assert.is_true(raw:find("<code>&lt;p&gt;inline&lt;/p&gt;</code>", 1, true) ~= nil)
Assert.is_true(raw:find("&amp; entity outside", 1, true) ~= nil or raw:find("& entity outside", 1, true) ~= nil)

-- 实体只解一轮：&amp;lt; 显示为 &lt; 文本，不会变成标签。
local ent = Markdown.toHtml("值是 &amp;lt;b&amp;gt; 与 &#x4e2d;文")
Assert.is_true(ent:find("&amp;lt;b&amp;gt;", 1, true) ~= nil)
Assert.is_nil(ent:find("<b>", 1, true))
Assert.is_true(ent:find("中文", 1, true) ~= nil)

-- 相对链接在官方仓库基址下解析；不会改写到镜像。
Assert.is_nil(Markdown.safeHref("./LICENSE"))
local href = Markdown.safeHref("./docs/a.md", { link_base = Markdown.linkBase({
    type = "github", owner = "Acme", repo = "nice-plugin", default_branch = "main",
}) })
Assert.eq(href, "https://github.com/Acme/nice-plugin/blob/main/docs/a.md")
Assert.is_nil(Markdown.safeHref("//evil.example/x", { link_base = "https://github.com/Acme/nice-plugin/blob/main/" }))

-- 表格样式归 Markdown，不进主题 Html 基础 CSS。
Assert.is_true(type(Markdown.CSS) == "string" and Markdown.CSS:find("md%-table", 1) ~= nil)
Assert.is_true(Markdown.CSS:find("md%-align%-left", 1) ~= nil)

return true
