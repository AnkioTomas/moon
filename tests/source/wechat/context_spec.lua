--[[--
source.wechat.context 离线用例：reader 状态本地生成、会话内固定、过期重建

@module tests.wechat_context_spec
--]]

local Assert = require("support.assert")
local Protocol = require("source.wechat.protocol")
local Context = require("source.wechat.context")

local real_time = os.time
local now = 1700000000
os.time = function(t) return t and real_time(t) or now end

-- 未缓存：按当前时间生成；psvts 模拟更早的出页时间，不能与 pclts 相同。
do
    Context.clear()
    local reader = Context.reader("b1", "c1")
    Assert.eq(reader.psvts, Protocol.encode(now - 1))
    Assert.eq(reader.pclts, Protocol.encode(now))
end

-- 会话内固定：进入阅读与之后的时长上报必须共用同一个 pc，entered 标记也要留住。
do
    Context.clear()
    local reader = Context.reader("b1", "c1")
    reader.entered = true
    local enter = Protocol.makeEnterReadPayload({
        book_id = "b1", chapter_uid = "c1", psvts = reader.psvts, pclts = reader.pclts,
    })
    now = now + 45
    local again = Context.reader("b1", "c1")
    Assert.is_true(again == reader, "TTL 内复用同一状态")
    local read = Protocol.makeReadPayload({
        book_id = "b1", chapter_uid = "c1", psvts = again.psvts, pclts = again.pclts,
        elapsed_seconds = 45,
    })
    Assert.eq(enter.pc, read.pc, "enter 与时长上报的 pc 必须一致")
    Assert.eq(enter.ps, read.ps)
end

-- 按章隔离；过 TTL 重建，entered 清掉以重新发进入阅读。
do
    Context.clear()
    local c1 = Context.reader("b1", "c1")
    c1.entered = true
    Assert.is_nil(Context.reader("b1", "c2").entered)
    now = now + 15 * 60
    local fresh = Context.reader("b1", "c1")
    Assert.is_nil(fresh.entered)
    Assert.eq(fresh.pclts, Protocol.encode(now))
end

os.time = real_time
