--[[--
source.18ta.mapper 离线用例：片段取自 18ta.com 真实页面（分类列表 / 书页 / 章节页）。

@module tests.source.18ta.mapper_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")
local Mapper = require("source.18ta.mapper")

-- /sort/<cat>/<page>.html 的一张书目卡片（完整 <li> 块）。
local LIST_HTML = [[
<div class="book_list">
<ul class="flex">
<li>
					<div class="img_span"><a href="/akshtml287895.html"><img class="lazy" src="https://www.18ta.com/static/shipsay/nocover.jpg" data-original="https://www.18ta.com/files/article/image/287/287895/287895s.jpg" title="从黄金一代开始" /><span>玄幻 / 连载</span></a></div>
					<div class="w100">
						<a href="/akshtml287895.html"><h2>从黄金一代开始</h2></a>
						<p class="indent"> 天赋爆棚的年轻人们拥有了，展示自己的表演场所。小说群:864747664
</p>
						<div class="li_bottom">
							<a href="/author/%E5%91%86%E5%91%86%E6%B5%B7%E5%8F%82/"><i class="fa fa-user-circle-o">&nbsp;呆呆海参</i></a>
							<div>
								<em class="orange">53万字</em><em class="blue">12小时前</em>
							</div>
						</div>
					</div>
				</li>
</div>
</ul>
]]

do
    local list = Mapper.list(LIST_HTML)
    Assert.eq(#list, 1)
    local b = list[1]
    Assert.eq(b.source_id, "18ta")
    Assert.eq(b.stable_id, "287895")
    Assert.eq(b.title, "从黄金一代开始")
    Assert.eq(b.authors, "呆呆海参")
    Assert.eq(b.category, "玄幻")
    Assert.eq(b.cover, "https://www.18ta.com/files/article/image/287/287895/287895s.jpg")
    Assert.is_true(b.intro:find("天赋爆棚", 1, true), "简介保留正文")
    Assert.eq(b.meta.status, "连载")
end

-- 空页与坏卡片：不报错、不产书。
Assert.is_nil(Mapper.list("<div></div>"), "坏响应不能当空书库")
Assert.is_nil(Mapper.list('<ul class="flex"><li><div class="img_span"><a href="/akshtmlx.html">x</a></div></li></ul>'))
Assert.len(Mapper.list('<ul class="flex"></ul>'), 0)

-- 书页：og:novel meta + .intro 简介 + og:image 封面。
local BOOK_HTML = [[
<html><head>
<meta property="og:novel:category" content="玄幻奇幻">
<meta property="og:novel:author" content="呆呆海参">
<meta property="og:novel:book_name" content="从黄金一代开始">
<meta property="og:novel:status" content="连载">
<meta property="og:image" content="https://www.18ta.com/files/article/image/287/287895/287895s.jpg"/>
</head><body>
<div id="info">
<div class="intro">
<p><p> 天赋爆棚的年轻人们拥有了，展示自己的表演场所。小说群:864747664</p></p>
</div>
<div class="section chapter_list">
<div class="title jcc">《从黄金一代开始》最新章节</div>
<ul>
<li><a href="/aks/287/287895/5448372.html" title="从黄金一代开始 第416章 再战火枪手雄鹿">第416章 再战火枪手雄鹿</a></li>
</ul>
</div>
</div>
<div id="catalog">
<div class="section chapter_list">
<ul id="ul_all_chapters">
<li><a href="/aks/287/287895/5447961.html" title="从黄金一代开始 第一章 红人大哥">第一章 红人大哥</a></li>
<li><a href="/aks/287/287895/5447962.html" title="从黄金一代开始 第二章 刻苦训练">第二章 刻苦训练</a></li>
</ul>
</div>
</div>
</body></html>
]]

do
    local b = Mapper.book(BOOK_HTML)
    Assert.eq(b.title, "从黄金一代开始")
    Assert.eq(b.authors, "呆呆海参")
    Assert.eq(b.category, "玄幻奇幻")
    Assert.eq(b.cover, "https://www.18ta.com/files/article/image/287/287895/287895s.jpg")
    Assert.eq(b.meta.status, "连载")
    Assert.is_true(b.intro:find("天赋爆棚", 1, true), "简介取 .intro 文本")
end

Assert.is_nil(Mapper.book("<html><body>no meta</body></html>"))

-- 目录只取 ul_all_chapters（页首「最新章节」预览块不得混入），章序即列表顺序。
do
    local toc = Mapper.toc(BOOK_HTML)
    Assert.eq(#toc, 2, "预览块不混入目录")
    Assert.eq(toc[1].idx, 1)
    Assert.eq(toc[1].uid, "/aks/287/287895/5447961.html")
    Assert.eq(toc[1].title, "第一章 红人大哥")
    Assert.eq(toc[1].origin, "/aks/287/287895/5447961.html")
    Assert.eq(toc[2].title, "第二章 刻苦训练")
end

Assert.eq(#Mapper.toc("<html><body></body></html>"), 0)

-- 章节正文：article 内部纯段落。
local CH_HTML = [[
<html><body>
<article id="article" class="content"><p> “教练，我想打篮球。”
</p><p> 室内篮球场上，约翰教练有些意外的看着眼前的小伙子。
</p></article>
</body></html>
]]

do
    local body = Mapper.chapterContent(CH_HTML)
    Assert.is_true(body:find("<p", 1, true), "正文是 <p> 段落")
    Assert.is_true(body:find("教练，我想打篮球", 1, true))
    Assert.is_nil(body:find("</article>", 1, true), "不含 article 标签本身")
end

Assert.is_nil(Mapper.chapterContent("<html><body><div>no article</div></body></html>"))
Assert.is_nil(Mapper.chapterContent('<article id="advert"><p>广告</p></article>'))
Assert.is_nil(Mapper.chapterContent('<article id="article"><p> </p></article>'))
Assert.eq(Mapper.chapterContent('<article id="article"><p>正文</p><script>bad()</script></article>'), "<p>正文</p>")

local path = "/aks/287/287895/5447961.html"
local function nextPage(href)
    return '<a id="next_url" href="' .. href .. '">下一页</a>'
end
Assert.eq(Mapper.chapterNext(nextPage("/aks/287/287895/5447961_2.html"), path), "/aks/287/287895/5447961_2.html")
Assert.is_nil(Mapper.chapterNext(nextPage("/aks/287/287895/5447962.html"), path))
Assert.is_nil(Mapper.chapterNext(nextPage("/akshtml287895.html"), path))
for _idx, href in ipairs({ path, "/aks/287/287895/5447961_4.html", "/aks/1/2/3.html", "https://evil.test/page" }) do
    local next_path, err = Mapper.chapterNext(nextPage(href), path)
    Assert.is_nil(next_path)
    Assert.eq(err, "响应无效")
end
local _next_path, err = Mapper.chapterNext("<p>没有导航</p>", path)
Assert.eq(err, "响应无效", "坏导航不能将第一段正文当完整章节")
