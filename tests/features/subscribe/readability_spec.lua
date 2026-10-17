--[[-- features.subscribe.readability：Readability.js 移植（打分、兄弟合并、prepArticle 清理、放宽重试、元数据）。 --]]

local Assert = require("support.assert")
require("support.stubs").install()
package.loaded["json"] = { decode = require("support.json_stub").decode }
local R = require("features.subscribe.readability")

local para = "这是正文段落，内容足够长，带有逗号，用来给父节点加分，模拟真实文章里的一段话，而不是导航或者广告。"
local sample = [[<!DOCTYPE html><html><head><title>t</title><style>p{}</style></head><body>
<div id="header" class="site-header"><a href="/">首页</a><a href="/a">关于我们这一栏</a></div>
<div class="sidebar"><p>]] .. para .. [[侧栏里的长段落也不要。</p></div>
<div class="main-wrap"><div class="post-content" id="article">
  <h1>标题</h1>
  <p>]] .. para .. [[</p>
  <p>]] .. para .. [[<a href="/x">文中链接</a></p>
  <p><img data-src="https://img.example.com/a.jpg" src="data:image/gif;base64,R0" style="width:100px" onclick="x()"></p>
  <p>]] .. para .. [[</p>
  <ul class="share-tools"><li><a href="/s1">分享到微博</a></li><li><a href="/s2">分享到微信</a></li></ul>
  <form><input name="q"></form>
</div>
<p class="note">]] .. para .. [[兄弟段落：链接少的长段落一起收。</p>
<div class="comments"><p>]] .. para .. [[评论区不要。</p></div>
</div>
<div class="related-posts"><a href="/r1">相关文章一的标题足够长</a><a href="/r2">相关文章二的标题足够长</a></div>
<div id="footer">版权所有</div>
<script>var p = "<p>脚本里的正文</p>";</script>
</body></html>]]

local out, meta = R.extract(sample, "https://site.com/post/1")
Assert.not_nil(out)
Assert.matches(out, "用来给父节点加分")
Assert.matches(out, "兄弟段落")
Assert.not_nil(out:find('<img src="https://img.example.com/a.jpg"/>', 1, true), "懒加载图换 src，属性只留 src")
Assert.not_nil(out:find('<a href="https://site.com/x">文中链接</a>', 1, true), "正文链接保留并补成绝对地址")
Assert.eq(meta.title, "t")
for _idx, bad in ipairs({ "侧栏", "评论区", "相关文章", "版权所有", "分享到", "关于我们", "<form", "<input", "脚本里", "style=", "onclick" }) do
    Assert.is_nil(out:find(bad, 1, true), "不该有：" .. bad)
end

-- 没有正文（太短 / 全是链接）返回 nil，调用方退回整页抽取。
Assert.eq(R.extract("<html><body><p>短</p></body></html>"), nil)
Assert.eq(R.extract('<body><div><a href="/1">' .. para .. '</a><a href="/2">' .. para .. "</a></div></body>"), nil)

-- 解析器宽容：未闭合的 p / li 隐式闭合，乱序闭合不崩；缺 html / body 时补上。
local doc = R.parse("<div><p>一<p>二</div></span><ul><li>甲<li>乙</ul>")
local body = doc.children[1].children[1]
Assert.eq(body.tag, "body")
Assert.eq(#body.children[1].children, 2, "两个 p 是兄弟")
Assert.eq(#body.children[2].children, 2, "两个 li 是兄弟")
R.MAX_ELEMS, doc = 3, nil
Assert.is_nil(R.parse("<p>1</p><p>2</p><p>3</p><p>4</p>"), "元素超上限不解析")
R.MAX_ELEMS = 20000

-- 元数据：JSON-LD 优先于 meta；署名节点从正文里摘掉；与标题重复的 h1 去掉；excerpt 取 og:description。
local long = string.rep("<p>" .. para .. "</p>", 6)
local page = [[<html lang="zh"><head><title>文章标题很长很长很长很长 | 站点</title>
<meta property="og:description" content="摘要 &amp; 说明"><meta property="og:site_name" content="站点名">
<script type="application/ld+json">{"@context":"https://schema.org","@type":"NewsArticle","headline":"文章标题很长很长很长很长","author":{"name":"张三"}}</script>
</head><body><article><h1>文章标题很长很长很长很长</h1><div class="byline">作者：李四</div>]] .. long .. [[</article></body></html>]]
local content, m = R.extract(page)
Assert.eq(m.title, "文章标题很长很长很长很长")
Assert.eq(m.byline, "张三", "JSON-LD 作者优先")
Assert.eq(m.excerpt, "摘要 & 说明")
Assert.eq(m.siteName, "站点名")
Assert.eq(m.lang, "zh")
Assert.is_nil(content:find("<h1", 1, true), "重复标题去掉")
Assert.not_nil(content:find('class="page"', 1, true), "包一层 readability-page")

-- 没有 JSON-LD 时署名取正文里的 byline 节点（并从正文删掉）；标题去掉「 | 站点」层级后缀（够长时）。
local page2 = [[<html><head><title>一个 足够 长的 英文 标题 | Site</title></head><body><div class="post"><p class="author">王五</p>]]
    .. long .. [[</div></body></html>]]
content, m = R.extract(page2)
Assert.eq(m.byline, "王五")
Assert.is_nil(content:find("王五", 1, true))
Assert.eq(m.title, "一个 足够 长的 英文 标题")

-- 署名里并排的元素（LWN：作者 + 日期）之间补空格，不粘在一起。
local page_lwn = [[<html><body><div class="post"><div class="byline">By <b>Joe B</b><span>October 6, 2026</span></div>]]
    .. long .. [[</div></body></html>]]
content, m = R.extract(page_lwn)
Assert.eq(m.byline, "By Joe B October 6, 2026")

-- noscript 里的真图替换占位图；srcset 补全为绝对地址；javascript: 链接拆掉。
local page3 = [[<html><body><div class="content">]] .. long .. [[<p><img src="data:image/gif;base64,R0lGOD" class="lazy"></p>
<noscript><img src="/real.jpg"></noscript><p><a href="javascript:void(0)">点我</a>]] .. para .. [[</p>
<p><img srcset="/a-1x.png 1x, /a-2x.png 2x"></p></div></body></html>]]
content = R.extract(page3, "https://b.com/x/y.html")
Assert.not_nil(content:find('src="https://b.com/real.jpg"', 1, true), "noscript 真图")
Assert.is_nil(content:find("data:image", 1, true))
Assert.is_nil(content:find("javascript:", 1, true))
Assert.matches(content, "点我")
Assert.not_nil(content:find('src="https://b.com/a-1x.png"', 1, true), "只有 srcset 的图取第一个地址")

-- 正文唯一容器的 class 像评论区：第一轮 strip unlikelys 删光，放宽重试找回来。
local page4 = "<html><body><div class='comment-body'>" .. long .. "</div></body></html>"
Assert.matches(R.extract(page4) or "", "模拟真实文章", "放宽重试")

-- 数据表（有 th）保留；只有一格的布局表格拆成段落。
local page5 = "<html><body><div class='entry'>" .. long
    .. "<table><tr><th>甲</th><th>乙</th></tr><tr><td>1</td><td>2</td></tr></table>"
    .. "<table><tr><td>单格表格里的一句话。</td></tr></table></div></body></html>"
content = R.extract(page5)
Assert.not_nil(content:find("<th>甲</th>", 1, true), "数据表保留")
Assert.not_nil(content:find("<p>单格表格里的一句话。</p>", 1, true), "单格表格拆成段落")

-- 无 class 的纯段落页面也能取出。
local plain = "<html><body><div>" .. string.rep("<p>" .. para .. "</p>", 3) .. "</div></body></html>"
Assert.matches(R.extract(plain) or "", "模拟真实文章")
