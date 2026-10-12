--[[--
extensions/moonsource-kavita.koplugin：xpointer ↔ Kavita pageNum / bookScrollId 换算。

@module tests.extensions.kavita.position_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, inject-field

local Assert = require("support.assert")
local Config = require("support.config")

local Position = dofile(Config.root() .. "/extensions/moonsource-kavita.koplugin/moonsource_kavita/position.lua")

-- spine：DocFragment[D] = spine D-1；单 spine 书没有下标。
Assert.eq(Position.spine("/body/DocFragment[8]/body/p[2]/text().0"), 7)
Assert.eq(Position.spine("/body[1]/DocFragment[1]/body[1]/p"), 0)
Assert.eq(Position.spine("/body/DocFragment/body/p"), 0)
Assert.is_nil(Position.spine(nil))
Assert.is_nil(Position.spine("#_doc_fragment_3"))

-- 上报：补全 [1]、丢文本偏移；两种 crengine 写法都认。
Assert.eq(Position.toScrollId("/body/DocFragment[8]/body/section/p[3]/text().0"), "//body/section[1]/p[3]")
Assert.eq(Position.toScrollId("/body[1]/DocFragment[8]/body[1]/div[2]/p/text()[1].5"), "//body/div[2]/p[1]")
Assert.eq(Position.toScrollId("/body/DocFragment/body/p[4]"), "//body/p[4]")
Assert.is_nil(Position.toScrollId("/body/DocFragment[2]/body"), "body 本身没有章内位置")
Assert.is_nil(Position.toScrollId(nil))

-- 下行：[1] 省略；读完（pageNum == pages）落回最后一个 spine；单 spine 书不带下标。
Assert.eq(Position.toXPointer(7, "//body/section[1]/p[3]", 10), "/body/DocFragment[8]/body/section/p[3]")
Assert.eq(Position.toXPointer(10, nil, 10), "/body/DocFragment[10]/body")
Assert.eq(Position.toXPointer(0, "//body/p[2]", 1), "/body/DocFragment/body/p[2]")
Assert.eq(Position.toXPointer(3, "id(\"x\")", 10), "/body/DocFragment[4]/body", "未解析的锚点只按 spine 定位")

-- 往返：上报出去的锚点拉回来落在同一段。
local here = "/body/DocFragment[5]/body/div[2]/p[7]/text().12"
Assert.eq(Position.toXPointer(Position.spine(here), Position.toScrollId(here), 9), "/body/DocFragment[5]/body/div[2]/p[7]")

-- 网页端的 id("X")：读本地 epub 第 spine 个文档找元素路径。
local files = {
    ["META-INF/container.xml"] = [[<container><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>]],
    ["OEBPS/content.opf"] = [[<package><manifest>
        <item id="c1" href="text/one.xhtml" media-type="application/xhtml+xml"/>
        <item href="text/two.xhtml" id="c2" media-type="application/xhtml+xml"/>
      </manifest><spine><itemref idref="c1"/><itemref idref="c2"/></spine></package>]],
    ["OEBPS/text/two.xhtml"] = [[<?xml version="1.0"?><html><body>
        <section><p>a</p><br/><p>b<img src="x"/></p><div><p id="target">c</p></div></section></body></html>]],
}
local opened, closed = nil, false
package.loaded["ffi/archiver"] = {
    Reader = {
        new = function()
            return {
                open = function(_self, path) opened = path; return path == "/book.epub" end,
                iterate = function() return function() end end,
                extractToMemory = function(_self, name) return files[name] end,
                close = function() closed = true end,
            }
        end,
    },
}
Assert.eq(Position.resolveScrollId("/book.epub", 1, 'id("target")'), "//body/section[1]/div[1]/p[1]")
Assert.eq(opened, "/book.epub")
Assert.is_true(closed)
Assert.eq(Position.resolveScrollId(nil, 1, "//body/p[2]"), "//body/p[2]", "自己上报的路径原样用")
Assert.is_nil(Position.resolveScrollId("/book.epub", 1, 'id("missing")'))
Assert.is_nil(Position.resolveScrollId("/book.epub", 5, 'id("target")'), "spine 越界")
Assert.is_nil(Position.resolveScrollId(nil, 1, 'id("target")'), "没下载过的书没法解析")
Assert.is_nil(Position.resolveScrollId("/other.epub", 1, 'id("target")'), "打不开的文件")
-- 划线锚点：按段落文本找路径，忽略空白、实体、脚注标记；跨段用首末行各定一段。
files["OEBPS/text/one.xhtml"] = [[<html><body><p>前言</p>
    <p>甲乙丙&amp;丁 戊己<sup>¹</sup>[3]庚辛壬癸</p><div><p>子丑寅卯辰巳</p></div></body></html>]]
local anchor = Position.anchor("丙&丁\n戊己", "/body/DocFragment[1]/body/p[2]/text().2", "/book.epub")
Assert.eq(anchor.pageNumber, 0)
Assert.eq(anchor.xPath, "//body/p[2]")
Assert.eq(anchor.endingXPath, "//body/p[2]")
anchor = Position.anchor("戊己庚辛壬癸\n子丑寅", "/body/DocFragment[1]/body/p[2]/text().6", "/book.epub")
Assert.eq(anchor.xPath, "//body/p[2]")
Assert.eq(anchor.endingXPath, "//body/div[1]/p[1]", "跨段")
anchor = Position.anchor("c", "/body/DocFragment[1]/body/p", "/book.epub")
Assert.is_nil(anchor, "单字太短，不猜")
anchor = Position.anchor("b", "/body/DocFragment[1]/body/p", "/book.epub")
Assert.is_nil(anchor)
files["OEBPS/text/two.xhtml"] = files["OEBPS/text/two.xhtml"]:gsub("<p>b", "<p>挪到第二章")
anchor = Position.anchor("挪到第二章", "/body/DocFragment[1]/body/p[2]", "/book.epub")
Assert.eq(anchor.pageNumber, 1, "pos0 所在 spine 没有就去邻近 spine 找")
Assert.eq(anchor.xPath, "//body/section[1]/p[2]")
Assert.is_nil(Position.anchor("不存在的文字", "/body/DocFragment[1]/body/p", "/book.epub"))
Assert.is_nil(Position.anchor("甲乙丙", "/body/DocFragment[1]/body/p", nil), "没下载过")

files["META-INF/container.xml"] = nil
Assert.is_nil(Position.resolveScrollId("/book.epub", 1, 'id("target")'), "坏 epub 降级成只按 spine")
