--[[--
Worker IPC 协议测试：半包、多包、非法帧和大小限制。

@module tests.workers.protocol_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")

Stubs.install()
package.preload["json"] = function()
    return {
        encode = function(v)
            return string.format('{"type":"%s","id":%d}', v.type, v.id or 0)
        end,
        decode = function(raw)
            local typ, id = raw:match('{"type":"([^"]+)","id":(%d+)}')
            if not typ then error("bad json") end
            return { type = typ, id = tonumber(id) }
        end,
    }
end
package.loaded["json"] = nil
package.loaded["workers.protocol"] = nil

local Protocol = require("workers.protocol")

local one = Protocol.encode({ type = "response", id = 7 })
local two = Protocol.encode({ type = "ready", id = 0 })
local decoder = Protocol.newDecoder()

local messages = assert(Protocol.feed(decoder, one:sub(1, 5)))
Assert.len(messages, 0)
messages = assert(Protocol.feed(decoder, one:sub(6) .. two))
Assert.len(messages, 2)
Assert.eq(messages[1].type, "response")
Assert.eq(messages[1].id, 7)
Assert.eq(messages[2].type, "ready")
Assert.is_true(Protocol.finish(decoder))

local bad = Protocol.newDecoder()
local parsed, err = Protocol.feed(bad, "zzzzzzzz")
Assert.is_nil(parsed)
Assert.matches(err, "invalid frame length")

local huge = Protocol.newDecoder()
parsed, err = Protocol.feed(huge, "04000001")
Assert.is_nil(parsed)
Assert.matches(err, "invalid frame length")

local incomplete = Protocol.newDecoder()
assert(Protocol.feed(incomplete, "00000004abc"))
local ok
ok, err = Protocol.finish(incomplete)
Assert.eq(ok, false)
Assert.matches(err, "incomplete frame")
