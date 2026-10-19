--[[-- ai.json：Markdown fence 剥离与 JSON 对象解码。 --]]

local Assert = require("support.assert")
local Json = require("support.json_stub")

package.preload["json"] = function()
    return { decode = Json.decode, encode = Json.encode }
end
package.preload["logger"] = function()
    return { warn = function() end, info = function() end, err = function() end }
end

local AiJson = require("ai.json")

local obj = assert(AiJson.decode('{"a":1}'))
Assert.eq(obj.a, 1)

local fenced = assert(AiJson.decode("```json\n{\"b\":2}\n```"))
Assert.eq(fenced.b, 2)

local prefixed = assert(AiJson.decode('说明如下 {"c":3} 完毕'))
Assert.eq(prefixed.c, 3)

Assert.is_nil(AiJson.decode(""))
Assert.is_nil(AiJson.decode("   "))
local _, empty_err = AiJson.decode("")
Assert.eq(empty_err, "AI 没有返回内容")

Assert.is_nil(AiJson.decode("not json at all"))
local _, bad_err = AiJson.decode("not json at all")
Assert.eq(bad_err, "AI 返回的内容无法解析")

-- 输出被截断：partial 时保留已完整的元素，默认仍判失败。
local cut = '{"characters":[{"name":"甲","description":"a}b"},{"name":"乙"}],"locations":[{"name":"丙","descr'
Assert.is_nil(AiJson.decode(cut))
local kept = assert(AiJson.decode(cut, true))
Assert.len(kept.characters, 2)
Assert.eq(kept.characters[1].description, "a}b")
Assert.len(kept.locations or {}, 0)
