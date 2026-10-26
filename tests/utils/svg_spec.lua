--[[-- SVG 根主题变量：只展开可确定的作用域，保留文字、图形与其它格式。 --]]
local Assert = require("support.assert")
local Svg = require("utils.svg")

-- 对应 brooker.co.za/blog/2026/10/04/encoders.html 三张图的主题结构。
local sample = [[<svg xmlns="http://www.w3.org/2000/svg" class="viz" viewBox="0 0 100 80">
<style>
 .viz { --surface: #fcfcfb; --ink: #0b0b0b; --series: #2a78d6; --tint: rgba(42,120,214,0.16); }
 @media (prefers-color-scheme: dark) { .viz { --surface: #1a1a19; --ink: #ffffff; } }
 .bg { fill: var(--surface); }
 .label { fill: var(--ink); }
 .plot { fill: var(--tint); stroke: var(--series); }
</style>
<title>literal var(--ink)</title>
<rect class="bg" width="100" height="80"/>
<text class="label" x="10" y="20">v19</text>
<circle class="plot" cx="50" cy="50" r="10"/>
</svg>]]
local result = Svg.normalize(sample)
Assert.matches(result, "fill: #fcfcfb")
Assert.matches(result, "fill: #0b0b0b")
Assert.matches(result, "stroke: #2a78d6")
Assert.is_true(result:find("fill: rgb(42,120,214)", 1, true) ~= nil)
Assert.matches(result, "fill%-opacity: 0%.16")
Assert.is_nil(result:find("@media", 1, true))
Assert.is_true(result:find("<title>literal var(--ink)</title>", 1, true) ~= nil)
Assert.matches(result, '<circle class="plot" cx="50" cy="50" r="10"/>')
Assert.eq(Svg.normalize(result), result, "规范化幂等")

local function svg(css, body, attrs)
    return '<svg xmlns="http://www.w3.org/2000/svg" ' .. (attrs or "") .. '><style>' .. css .. '</style>'
        .. (body or '<rect width="10" height="10"/>') .. '</svg>'
end

-- 没有 CSS 变量的图片字节不变，保留内容寻址与复用行为。
local plain = svg(".bg { fill: white; }")
Assert.eq(Svg.normalize(plain), plain)

-- 根的 id / class / 类型与 :root；按优先级取值，不能让后面的低优先级覆盖。
local cascade = svg([[
 #chart { --ink: red; }
 svg.viz { --ink: blue; }
 svg { --ink: green; }
 .label { fill: var(--ink); }
]], nil, 'id="chart" class="viz other"')
Assert.matches(Svg.normalize(cascade), "fill: red")
local inline = svg(':root { --ink: red; } .label { fill: var(--ink); }', nil, 'style="--ink: blue"')
Assert.matches(Svg.normalize(inline), "fill: blue")
local important = svg(':root { --ink: red !important; } .label { fill: var(--ink); }', nil, 'style="--ink: blue"')
Assert.matches(Svg.normalize(important), "fill: red")

-- 浅色媒体声明参与级联，深色分支不参与；括号、rgba 逗号、嵌套备用值不被截断。
local light = svg([[
 :root { --ink: black; --alias: var(--ink); }
 @media (prefers-color-scheme: light) { :root { --ink: navy; } }
 .label { fill: var(--alias); stroke: var(--missing, var(--also-missing, rgb(1, 2, 3))); }
]])
local expanded = Svg.normalize(light)
Assert.matches(expanded, "fill: navy")
Assert.is_true(expanded:find("rgb(1, 2, 3)", 1, true) ~= nil)
Assert.is_nil(expanded:find("var%s*%("))
local attribute = svg(':root { --ink: #123456; }', '<rect fill="var(--ink)" style="stroke: var(--ink)"/>')
Assert.matches(Svg.normalize(attribute), 'fill="#123456" style="stroke: #123456"')

-- 局部重定义不能错误提升到全局，整个 SVG 保留原样。
for _, local_scope in ipairs({
    svg(':root { --ink: black; } .nested { --ink: white; } .label { fill: var(--ink); }'),
    svg(':root { --ink: black; }', '<g style="--ink: white"><rect fill="var(--ink)"/></g>'),
    svg(':root { --ink: black; } .nested svg { --ink: white; }', '<rect fill="var(--ink)"/>'),
    svg('@supports (color: red) { :root { --ink: red; } }', '<rect fill="var(--ink)"/>'),
}) do
    Assert.eq(Svg.normalize(local_scope), local_scope)
end

-- 值无法展开或存在依赖环，不写出半处理的 SVG。
for _, unresolved in ipairs({
    svg('.label { fill: var(--missing); }'),
    svg(':root { --a: var(--b); --b: var(--a); } .label { fill: var(--a); }'),
    svg(':root { --a: var(--a, red); } .label { fill: var(--a, blue); }'),
}) do
    Assert.eq(Svg.normalize(unresolved), unresolved)
end

-- 注释中的花括号和声明不能污染变量表。
local comments = svg('/* { --ink: white; } */ :root { --ink: black; } .label { fill: var(--ink); }')
Assert.matches(Svg.normalize(comments), "fill: black")

-- 同一组图的透明命中区域也会被旧引擎画成黑块；静态图使用 none 保留不绘制语义。
local transparent = svg('.hit { fill: transparent; stroke: transparent; }',
    '<title>transparent</title><rect fill="transparent" stroke="TRANSPARENT" style="fill: transparent; stroke: transparent"/>')
local paint = Svg.normalize(transparent)
Assert.matches(paint, '%.hit {fill: none;stroke: none;%s*}')
Assert.is_true(paint:find('fill="none" stroke="none" style="fill: none;stroke: none"', 1, true) ~= nil)
Assert.is_true(paint:find('<title>transparent</title>', 1, true) ~= nil)
local transparent_var = svg(':root { --hit: transparent; } rect { fill: var(--hit); }')
Assert.matches(Svg.normalize(transparent_var), 'rect {fill: none;%s*}')

local rgba = svg('.box { fill: rgba(42,120,214,0.16); stroke: blue; fill-opacity: 0.5; opacity: 0.8; }',
    '<rect fill="rgba(1,2,3,0.4)"/>')
local alpha = Svg.normalize(rgba)
Assert.matches(alpha, 'fill%-opacity: 0%.08')
Assert.matches(alpha, 'opacity: 0%.8')
Assert.is_true(alpha:find('fill="rgb(1,2,3)" fill-opacity="0.4"', 1, true) ~= nil)
Assert.eq(Svg.normalize(alpha), alpha)
