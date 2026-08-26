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
Assert.eq(empty_err, "empty AI response")

Assert.is_nil(AiJson.decode("not json at all"))
local _, bad_err = AiJson.decode("not json at all")
Assert.eq(bad_err, "AI did not return JSON")
