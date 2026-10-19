--[[--
QQ阅读已购 VIP 章节解密（Fock 转译版）与乱序还原离线用例。

@module tests.source.qqreader_fock_spec
--]]
---@diagnostic disable: undefined-field

local Assert = require("support.assert")
local Sample = require("support.qqreader_fock_sample")
local Fock = require("source.qqreader.fock")
local Scramble = require("source.qqreader.scramble")

local plain, err = Fock.decrypt(Sample.content, Sample.chapter_id, Sample.keypool, Sample.version, Sample.fuid)
Assert.is_nil(err)
Assert.eq(#plain, 20816)
Assert.eq(plain:sub(1, 15), '<p class="p0"><')

-- 乱序还原：order 重排、first-letter 藏字 + ::after / attr() 补字、sy-0 占位丢弃、其余码位按字形表替换
local css = "yb{order:1;}ya{order:2;}yc{order:3;}"
    .. ".p1 ya::first-letter{font-size:0}.p1 ya::after{content:'乙'}"
    .. ".p1 yc::after{content:attr(k)}"
local html = '<p class="p1"><ya>X</ya><yc k="丙"></yc><yb>甲</yb></p>'
    .. '<p>　　<y class="sy-0">占</y>正<y class="sy-1">䤉</y>文䨀</p>'
local paragraphs = Scramble.paragraphs(html, css)
Assert.eq(paragraphs[1], "甲乙丙")
local rare, han = Scramble.codes(paragraphs)
Assert.eq(#rare, 2)
Assert.eq(#han, 5)
-- randomFont：认得的换、认不出的 □；fixedFont：认得的换、认不出的 □、字体里没有的码位（nil）原样留
Assert.eq(Scramble.text(paragraphs, { [0x4909] = "来" }, { [0x6B63] = "对", [0x6587] = false }),
    "甲乙丙\n　　对来□□")
