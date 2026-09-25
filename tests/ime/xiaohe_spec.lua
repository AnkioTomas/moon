--[[-- 小鹤双拼键码 → 全拼翻译（真实拼音音节表）。
@module tests.ime.xiaohe_spec
--]]

local Assert = require("support.assert")
local Xiaohe = require("ime.xiaohe")

local cases = {
    nihc = "nihao",
    vsgo = "zhongguo",
    uuru = "shuru",
    iytm = "chuntian",
}

-- 零声母：单韵母双写、双字母原样、三字母首字母 + 韵母键
cases.aa = "a"
cases.ai = "ai"
cases.ah = "ang"
cases.eg = "eng"
cases.er = "er"
cases.oo = "o"
cases.ou = "ou"

-- 一键多韵靠合法音节消歧
cases.js = "jiong"
cases.ls = "long"
cases.kk = "kuai"
cases.xk = "xing"
cases.nl = "niang"
cases.gl = "guang"
cases.lv = "lv"
cases.vv = "zhui"
cases.lt = "lve"
cases.jt = "jue"
cases.yr = "yuan"
cases.yy = "yun"
cases.ww = "wei"
cases.yz = "you"

for code, want in pairs(cases) do
    Assert.eq(Xiaohe.toPinyin(code), want, code)
end

-- 末尾单键展开为声母前缀，交给拼音词库做前缀查询
Assert.eq(Xiaohe.toPinyin("nihcv"), "nihaozh")
Assert.eq(Xiaohe.toPinyin("nihci"), "nihaoch")
Assert.eq(Xiaohe.toPinyin("nihcu"), "nihaosh")
Assert.eq(Xiaohe.toPinyin("nihch"), "nihaoh")
Assert.eq(Xiaohe.toPinyin("n"), "n")

-- 非法键对：无候选
Assert.eq(Xiaohe.toPinyin("bh"), "bang")
Assert.eq(Xiaohe.toPinyin("fk"), "")
Assert.eq(Xiaohe.toPinyin("nifk"), "")
Assert.eq(Xiaohe.toPinyin(""), "")
