--[[-- utils.charset：声明编码的探测与转 UTF-8。 --]]

local Assert = require("support.assert")
local Charset = require("utils.charset")
local Text = require("utils.text")

local gbk = "\214\208\206\196" -- 「中文」GBK

Assert.eq(Charset.detect("x", "text/html; charset=GBK"), "gbk", "HTTP 头")
Assert.eq(Charset.detect('<?xml version="1.0" encoding="GB2312"?><rss/>'), "gb2312", "XML 声明")
Assert.eq(Charset.detect('<meta http-equiv="Content-Type" content="text/html; charset=gbk">'), "gbk", "meta http-equiv")
Assert.eq(Charset.detect('<META charset="big5">'), "big5", "meta charset")
Assert.eq(Charset.detect("\239\187\191<rss/>", "text/xml; charset=gbk"), "utf-8", "BOM 优先")
Assert.is_nil(Charset.detect("<rss/>"), "没声明")

Assert.eq(Charset.toUtf8("中文", "text/html; charset=utf-8"), "中文")
Assert.eq(Charset.toUtf8("\239\187\191中文"), "中文", "去 BOM")
Assert.eq(Charset.toUtf8("<meta charset=gbk>" .. gbk), "<meta charset=gbk>中文", "meta 声明的 GBK")
Assert.eq(Charset.toUtf8(gbk, "text/html;charset=GB2312"), "中文", "GB2312 按 GBK 超集解")
Assert.eq(Charset.toUtf8(gbk .. "\255" .. gbk, "text/html;charset=gbk"):find("中文", 1, true), 1, "坏字节跳过不丢后文")
local text, name = Charset.toUtf8("abc", "text/html; charset=no-such-charset")
Assert.is_nil(text)
Assert.eq(name, "no-such-charset", "转不了如实报编码名")

Assert.eq(Text.xmlDecode("a&#0;b&#xD800;c&#20013;"), "abc中", "NUL 与代理区丢掉")
