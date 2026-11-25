--[[-- convert.md2html：通用 Markdown → 安全 HTML（不渲染图片），同时覆盖 md4c 与纯 Lua 兜底引擎。 --]]

local Assert = require("support.assert")
local Md2Html = require("convert.md2html")

-- safeHref：协议白名单与同源相对路径解析。
Assert.is_nil(Md2Html.safeHref("javascript:alert(1)"))
Assert.is_nil(Md2Html.safeHref("data:text/html,hi"))
Assert.is_nil(Md2Html.safeHref("vbscript:msgbox(1)"))
Assert.is_nil(Md2Html.safeHref("file:///etc/passwd"))
Assert.is_nil(Md2Html.safeHref("../secret"))
Assert.is_nil(Md2Html.safeHref("./LICENSE"))
Assert.is_nil(Md2Html.safeHref(""))
Assert.is_nil(Md2Html.safeHref(nil))
Assert.eq(Md2Html.safeHref("https://example.com/a"), "https://example.com/a")
Assert.eq(Md2Html.safeHref("http://example.com"), "http://example.com")
Assert.eq(Md2Html.safeHref("mailto:a@example.com"), "mailto:a@example.com")

local base = "https://github.com/Acme/nice-plugin/blob/main/"
Assert.eq(
    Md2Html.safeHref("./docs/a.md", { link_base = base }),
    "https://github.com/Acme/nice-plugin/blob/main/docs/a.md"
)
Assert.eq(
    Md2Html.safeHref("guide/intro.md", { link_base = "https://docs.example.com/v1/" }),
    "https://docs.example.com/v1/guide/intro.md"
)
Assert.is_nil(Md2Html.safeHref("//evil.example/x", { link_base = base }))
Assert.is_nil(Md2Html.safeHref("./a.md", { link_base = "javascript:alert(1)" }))

-- 样式表归转换器本身，含表格与对齐类。
Assert.is_true(type(Md2Html.CSS) == "string" and Md2Html.CSS:find("md%-table", 1) ~= nil)
Assert.is_true(Md2Html.CSS:find("md%-align%-left", 1) ~= nil)

-- 同一套用例跑在所有可用引擎上（lua 必跑；md4c 可用时必跑）。
local engines = { "lua" }
if Md2Html.engine() == "md4c" then
    engines[#engines + 1] = "md4c"
end

for _i, eng in ipairs(engines) do
    local function render(src, extra)
        local opts = { engine = eng }
        if extra then
            for k, v in pairs(extra) do opts[k] = v end
        end
        return Md2Html.toHtml(src, opts)
    end

    -- 边界输入
    Assert.eq(render(nil), "")
    Assert.eq(render(""), "")

    -- 基础语法 + 危险链接剥去 <a> 保留文字 + 图片不渲染且不留 src
    local html = render([[# 标题
这是 **加粗**、*斜体*、~~删除~~ 和 `code`。

[官网](https://example.com) 和 [坏链](javascript:alert(1))。

![示意图](https://example.com/token.png)

![](https://example.com/blank.png)

[![徽章](https://img.shields.io/badge/MIT)](https://example.com/mit)

```lua
return "<script>x()</script>"
```

- 一项
- 二项
]])
    Assert.is_true(html:find("<h1>标题</h1>", 1, true) ~= nil, eng .. ": h1")
    Assert.is_true(html:find("<strong>加粗</strong>", 1, true) ~= nil, eng .. ": strong")
    Assert.is_true(html:find("<em>斜体</em>", 1, true) ~= nil, eng .. ": em")
    Assert.is_true(html:find("<del>删除</del>", 1, true) ~= nil, eng .. ": del")
    Assert.is_true(html:find("<code>code</code>", 1, true) ~= nil, eng .. ": code")
    Assert.is_true(html:find('href="https://example.com"', 1, true) ~= nil, eng .. ": good link")
    Assert.is_nil(html:find("javascript:", 1, true), eng .. ": no js href")
    Assert.is_true(html:find("坏链", 1, true) ~= nil, eng .. ": keep bad link text")
    Assert.is_nil(html:find("坏链</a>", 1, true), eng .. ": no stray </a>")
    Assert.is_nil(html:find("<img", 1, true), eng .. ": no img")
    Assert.is_nil(html:find("token.png", 1, true), eng .. ": no img src")
    Assert.is_nil(html:find("blank.png", 1, true), eng .. ": no empty-alt img src")
    Assert.is_nil(html:find("shields.io", 1, true), eng .. ": no badge img src")
    Assert.is_true(html:find("［图片：示意图］", 1, true) ~= nil, eng .. ": alt placeholder")
    Assert.is_true(html:find("［图片：徽章］", 1, true) ~= nil, eng .. ": badge alt")
    Assert.is_true(html:find('href="https://example.com/mit"', 1, true) ~= nil, eng .. ": badge link")
    Assert.is_true(html:find("&lt;script&gt;", 1, true) ~= nil, eng .. ": escaped code")
    Assert.is_nil(html:find("<script>", 1, true), eng .. ": no raw script")
    Assert.is_true(html:find("<li>", 1, true) ~= nil, eng .. ": list")

    -- 脚本（含大写）与注释剥离
    local script_out = render("<SCRIPT>alert(1)</SCRIPT>\n\n安全正文")
    Assert.is_true(script_out:find("&lt;script&gt;", 1, true) ~= nil, eng .. ": script trace")
    Assert.is_nil(script_out:find("<script>", 1, true), eng .. ": no script tag")
    Assert.is_nil(script_out:find("alert(1)", 1, true), eng .. ": drop script body")
    Assert.is_true(script_out:find("安全正文", 1, true) ~= nil, eng .. ": keep trailing after uppercase SCRIPT")

    -- GFM 管道表格：对齐、代码、转义管道
    local table_html = render([[
| 名称 | 对齐 | 管道 |
| :--- | :---: | ---: |
| 中文 | `code` | a \| b |
| x | y | z |
]])
    Assert.is_true(table_html:find('<table class="md-table">', 1, true) ~= nil, eng .. ": md-table")
    Assert.is_true(table_html:find("<th", 1, true) ~= nil, eng .. ": th")
    Assert.is_true(table_html:find("<td", 1, true) ~= nil, eng .. ": td")
    Assert.is_true(table_html:find("中文", 1, true) ~= nil, eng .. ": cell text")
    Assert.is_true(table_html:find("<code>code</code>", 1, true) ~= nil, eng .. ": cell code")
    Assert.is_true(table_html:find("a | b", 1, true) ~= nil, eng .. ": escaped pipe")
    Assert.is_true(table_html:find('class="md-align-left"', 1, true) ~= nil, eng .. ": align left")
    Assert.is_true(table_html:find('class="md-align-center"', 1, true) ~= nil, eng .. ": align center")
    Assert.is_true(table_html:find('class="md-align-right"', 1, true) ~= nil, eng .. ": align right")
    Assert.is_nil(table_html:find("| 名称 |", 1, true), eng .. ": parsed table")

    -- 原始 HTML：白名单放行 + 危险属性剥离 + 原生 <a> 走 link_base + 原生 <img> 不渲染
    local raw = render([[
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
<a href="./docs/a.md">文档</a>
<img src="https://evil.example/a.png" alt="示意图">
<img src="https://evil.example/noalt.png">
]], { link_base = base })
    Assert.is_true(raw:find('<p align="center"', 1, true) ~= nil, eng .. ": raw p align")
    Assert.is_true(raw:find("md-align-center", 1, true) ~= nil, eng .. ": raw align class")
    Assert.is_true(raw:find("<strong>标题</strong>", 1, true) ~= nil, eng .. ": raw strong")
    Assert.is_true(raw:find('<table class="md-table">', 1, true) ~= nil, eng .. ": raw table class")
    Assert.is_true(raw:find("<th>A</th>", 1, true) ~= nil, eng .. ": raw th")
    Assert.is_true(raw:find("<td>一</td>", 1, true) ~= nil, eng .. ": raw td")
    Assert.is_nil(raw:find("<script>", 1, true), eng .. ": raw no script")
    Assert.is_true(raw:find("&lt;script&gt;", 1, true) ~= nil, eng .. ": raw script trace")
    Assert.is_nil(raw:find("onclick", 1, true), eng .. ": no onclick")
    Assert.is_nil(raw:find("style=", 1, true), eng .. ": no style")
    Assert.is_nil(raw:find("<img", 1, true), eng .. ": raw no img")
    Assert.is_nil(raw:find("evil.example", 1, true), eng .. ": raw no img src")
    Assert.is_true(raw:find("［图片：示意图］", 1, true) ~= nil, eng .. ": raw img alt")
    Assert.is_true(raw:find('href="https://github.com/Acme/nice-plugin/blob/main/docs/a.md"', 1, true) ~= nil,
        eng .. ": raw a link_base")
    Assert.is_true(raw:find("<pre><code>", 1, true) ~= nil, eng .. ": pre code")
    Assert.is_true(raw:find("&lt;p&gt;标签应保持文本&lt;/p&gt;", 1, true) ~= nil, eng .. ": fenced code escaped")
    Assert.is_true(raw:find("<code>&lt;p&gt;inline&lt;/p&gt;</code>", 1, true) ~= nil, eng .. ": inline code escaped")
    Assert.is_true(raw:find("&amp; entity outside", 1, true) ~= nil, eng .. ": entity preserved")

    -- 实体只解一轮：&amp;lt; 不变标签；&#60; 不变原生 <；&#x4e2d; 解成中文。
    local ent = render("值是 &amp;lt;b&amp;gt; 与 &#x4e2d;文 和 <p>&#60;script&#62; &#x4e2d;</p>")
    Assert.is_true(ent:find("&amp;lt;b&amp;gt;", 1, true) ~= nil, eng .. ": single decode")
    Assert.is_nil(ent:find("<b>", 1, true), eng .. ": no injected b")
    Assert.is_nil(ent:find("<script>", 1, true), eng .. ": no numeric entity tag injection")
    Assert.is_true(ent:find("中文", 1, true) ~= nil, eng .. ": numeric CJK")

    -- 未闭合围栏代码块不崩且转义内部标签
    local unclosed = render("```lua\nlocal x = '<script>'\n")
    Assert.is_true(unclosed:find("<pre><code>", 1, true) ~= nil, eng .. ": unclosed fence opens")
    Assert.is_true(unclosed:find("&lt;script&gt;", 1, true) ~= nil, eng .. ": unclosed fence escapes")
    Assert.is_nil(unclosed:find("<script>", 1, true), eng .. ": unclosed fence safe")
end

return true
