--[[--
source.wechat.context 离线用例：reader 状态缓存与 pclts 固定

@module tests.wechat_context_spec
--]]

local Assert = require("support.assert")
local Protocol = require("source.wechat.protocol")
local Context = require("source.wechat.context")

-- 阅读页没给 pclts：记住时固定一次，进入阅读与之后的时长上报必须共用同一个 pc。
do
    local real_time = os.time
    local now = 1700000000
    os.time = function(t) return t and real_time(t) or now end
    Context.clear()
    Context.rememberReader("b1", "c1", { psvts = "ps", token = "tk" })
    local reader = Context.reader("b1", "c1")
    Assert.eq(reader.pclts, Protocol.encode(1700000000))

    local enter = Protocol.makeEnterReadPayload({
        book_id = "b1", chapter_uid = "c1", psvts = reader.psvts, pclts = reader.pclts,
    })
    now = now + 45
    local read = Protocol.makeReadPayload({
        book_id = "b1", chapter_uid = "c1", psvts = reader.psvts, pclts = reader.pclts,
        token = reader.token, elapsed_seconds = 45,
    })
    os.time = real_time
    Assert.eq(enter.pc, read.pc, "enter 与时长上报的 pc 必须一致")
    Assert.is_nil(Context.reader("b1", "c1"), "恢复真实时间后旧状态已过 TTL")
end

-- 阅读页给了 pclts：原样使用。
do
    Context.clear()
    Context.rememberReader("b1", "c1", { psvts = "ps", pclts = "page-pc" })
    Assert.eq(Context.reader("b1", "c1").pclts, "page-pc")
end

-- 缺 psvts 的状态不可用。
do
    Context.clear()
    Context.rememberReader("b1", "c1", { pclts = "page-pc" })
    Assert.is_nil(Context.reader("b1", "c1"))
end
