--[[--
阅读进度的原文字符坐标与本地 XPointer 双向映射。

@module tests.book.annotations_spec
--]]

local Assert = require("support.assert")
local Annotations = require("book.annotations")

do
    local html = "<html><body><p>" .. string.rep("甲", 12000)
        .. "乙&amp;<b>丙😀丁</b>戊</p></body></html>"
    local wire, flow = Annotations.wireMapping(html), Annotations.flow(html)
    local locator = Annotations.fromWireOffset(wire, flow, 12015)
    Assert.eq(locator, "/html/body/p/text()[1].12000")
    local offset, summary = Annotations.toWirePosition(wire, flow, locator)
    Assert.eq(offset, 12015, "UTF-8 按字符计，不是字节或万分比")
    Assert.eq(summary, "乙&丙😀丁戊")
    locator = Annotations.fromWireOffset(wire, flow, 12024)
    Assert.eq(locator, "/html/body/p/b/text().0")
    Assert.eq(Annotations.toWirePosition(wire, flow, locator), 12024)
    locator = Annotations.fromWireOffset(wire, flow, 0)
    Assert.eq(locator, "/html/body/p/text()[1].0", "标签中的位置落到后续正文")
    Assert.eq(Annotations.toWirePosition(wire, flow, "/missing/text().0"), nil)
end

do
    local text = "重复正文。" .. string.rep("甲", 40) .. "重复正文。"
    local wire = Annotations.plainMapping(text)
    local flow = Annotations.flow("<html><body><h1>章名</h1><p>" .. text .. "</p></body></html>")
    local locator = Annotations.fromWireOffset(wire, flow, 45)
    Assert.eq(locator, "/html/body/p/text().45", "新增章名不改变 TXT 原文坐标")
    Assert.eq(Annotations.toWirePosition(wire, flow, locator), 45)
    Assert.eq(Annotations.fromWireOffset(Annotations.plainMapping(""), flow, 0), nil)
end

do
    local wire = Annotations.plainMapping("目标正文")
    local flow = Annotations.flow("<html><body><p>目标正文</p><p>目标正文</p></body></html>")
    Assert.eq(Annotations.fromWireOffset(wire, flow, 0), nil, "改写后重复次数不符不能随便挑一个")
end
