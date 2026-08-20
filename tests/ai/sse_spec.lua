--[[-- ai.sse：OpenAI SSE data 行解析。 --]]

local Assert = require("support.assert")
local Json = require("support.json_stub")

package.preload["json"] = function()
    return { decode = Json.decode, encode = Json.encode }
end

local SSE = require("ai.sse")
local parser = SSE.parser()

Assert.is_nil(parser.feed(""))
local d1 = 'data: {"choices":[{"delta":{"content":"Hel"}}]}\n'
Assert.eq(parser.feed(d1), "Hel")
local d2 = 'data: {"choices":[{"delta":{"content":"lo"}}]}\n'
Assert.eq(parser.feed(d2), "lo")
Assert.is_nil(parser.feed("data: [DONE]\n"))
Assert.is_nil(parser.feed(": comment\n"))
Assert.eq(parser.finish(), "Hello")

-- 残缺行缓冲
local p2 = SSE.parser()
local partial = 'data: {"choices":[{"delta":{"content":"ab'
Assert.is_nil(p2.feed(partial))
Assert.eq(p2.feed('c"}}]}\n'), "abc")
Assert.eq(p2.finish(), "abc")

-- CRLF
local p3 = SSE.parser()
local crlf = 'data: {"choices":[{"delta":{"content":"x"}}]}\r\n'
Assert.eq(p3.feed(crlf), "x")
Assert.eq(p3.finish(), "x")
