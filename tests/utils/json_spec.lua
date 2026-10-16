--[[-- utils.json：luajson 逐半编码的代理对（CESU-8）修成正常 UTF-8。 --]]

local Assert = require("support.assert")

local GRIN = "\240\159\152\128"         -- U+1F600
local CESU = "\237\160\189\237\184\128" -- 同一码点逐半编码

-- luajson 对 `["A\\uD83D\\uDE00B"]` 的实际输出就是逐半编码（已用 KOReader 自带 luajson 实测）；这里用替身复现
package.loaded["json"] = { decode = function(text)
    if text == "bad" then return nil, "boom" end
    return { [CESU] = { "A" .. CESU .. "B" }, n = 1 }
end }
package.loaded["utils.json"] = nil
local Json = require("utils.json")

Assert.eq(Json.fixSurrogates("A" .. CESU .. "B中"), "A" .. GRIN .. "B中")
Assert.eq(Json.fixSurrogates("纯文本 " .. GRIN), "纯文本 " .. GRIN, "正常 UTF-8 不动")
Assert.eq(Json.fixSurrogates("\237\160\189x"), "\237\160\189x", "孤立高位不动")

local v = Json.decode("x")
Assert.eq(v[GRIN][1], "A" .. GRIN .. "B", "值和键都修")
Assert.is_nil(v[CESU])
Assert.eq(v.n, 1)
local nv, err = Json.decode("bad")
Assert.is_nil(nv)
Assert.eq(err, "boom", "第二返回值透传")
