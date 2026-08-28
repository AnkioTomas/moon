--[[--
source.wechat.protocol 离线用例（依赖本机 koreader/base 的 ffi/sha2）

@module tests.wechat_protocol_spec
--]]

local Assert = require("support.assert")
local md5 = require("ffi/sha2").md5
local Protocol = require("source.wechat.protocol")

-- encode：数字 vs 非数字路径不同；结果确定性
do
    Assert.eq(Protocol.encode("123"), "2023270027b202cb962a56f")
    Assert.eq(Protocol.encode("abc"), "900427206616263900156d7")
    -- 同一输入多次一致
    Assert.eq(Protocol.encode("3300022941"), Protocol.encode("3300022941"))
end

-- sortedQuery：按 key 排序，跳过 s，做 urlencode
do
    Assert.eq(Protocol.sortedQuery({ b = 2, a = 1, s = "drop" }), "a=1&b=2")
    Assert.eq(Protocol.sortedQuery({ q = "a b" }), "q=a%20b")
    Assert.eq(Protocol.sortedQuery({ t = true, f = false }), "f=false&t=true")
end

-- sign：对 query 串确定性哈希
do
    Assert.eq(Protocol.sign("a=1&b=2"), "2a0a2922")
    Assert.eq(Protocol.sign(""), Protocol.sign(""))
end

-- readerUrl
do
    local url = Protocol.readerUrl("3300022941")
    Assert.is_true(url:find("^https://weread%.qq%.com/web/reader/", 1) ~= nil)
    Assert.is_true(url:find("k", 1, true) == nil)

    local with_ch = Protocol.readerUrl("3300022941", "100")
    Assert.is_true(with_ch:find("k" .. Protocol.encode("100"), 1, true) ~= nil)
    Assert.is_true(with_ch:find(Protocol.encode("3300022941"), 1, true) ~= nil)
end

-- contentParams：结构完整，s 与 sortedQuery 自洽；固定时间/随机
do
    local real_time, real_random = os.time, math.random
    os.time = function()
        return 1700000000
    end
    math.random = function()
        return 3
    end
    local psvts = "not-matching"
    local params = Protocol.contentParams("bid", "cuid", psvts, { style = true, sc = 2 })
    os.time = real_time
    math.random = real_random

    Assert.eq(params.b, Protocol.encode("bid"))
    Assert.eq(params.c, Protocol.encode("cuid"))
    Assert.eq(params.ps, psvts)
    Assert.eq(params.sc, 2)
    Assert.eq(params.st, 1)
    Assert.eq(params.prevChapter, false)
    Assert.not_nil(params.s)
    local expect_s = Protocol.sign(Protocol.sortedQuery(params))
    Assert.eq(params.s, expect_s)
end

-- contentParams：encode(ct)==psvts 时 ct 递增
do
    local ct0 = 1700000001
    local real_time, real_random = os.time, math.random
    os.time = function()
        return ct0
    end
    math.random = function()
        return 1
    end
    local psvts = Protocol.encode(ct0)
    local params = Protocol.contentParams("b", "c", psvts)
    os.time = real_time
    math.random = real_random
    Assert.eq(params.ct, tostring(ct0 + 1))
    Assert.eq(params.pc, Protocol.encode(ct0 + 1))
end

-- decodeShards：错误路径
do
    local t, err = Protocol.decodeShards()
    Assert.is_nil(t)
    Assert.eq(err, "empty shards")

    t, err = Protocol.decodeShards("too-short")
    Assert.is_nil(t)
    Assert.eq(err, "shard too short")

    t, err = Protocol.decodeShards(string.rep("0", 32) .. "body-with-bad-md5!!!!")
    Assert.is_nil(t)
    Assert.eq(err, "shard md5 mismatch")
end

-- decodeShards：长正文（swapPositions 多位置分支）
--
-- 反向构造：从明文 base64 出发，按 reverseSwaps 的交换序列倒序施加得到混淆串，
-- 解码后必须还原。交换下标恒小于 len-n-1，不会碰到 swapPositions 读取的尾部字节，
-- 所以位置表可以直接从明文 base64 上算。
do
    local function upvalue(fn, name)
        local i = 1
        while true do
            local n, v = debug.getupvalue(fn, i)
            if n == nil then
                return nil
            end
            if n == name then
                return v
            end
            i = i + 1
        end
    end
    local decodeEncodedBody = upvalue(Protocol.decodeShards, "decodeEncodedBody")
    Assert.not_nil(decodeEncodedBody)
    local swapPositions = upvalue(decodeEncodedBody, "swapPositions")
    Assert.not_nil(swapPositions)

    local plain = string.rep("微信读书章节正文 weread chapter body. ", 20)
    local b64 = require("utils.text").base64Encode(plain)
    Assert.is_true(#b64 > 200)

    local positions = swapPositions(b64)
    Assert.is_true(#positions > 2, "长输入应走多位置分支")
    Assert.eq(#positions % 2, 0)

    -- reverseSwaps 实际执行的交换序列
    local ops = {}
    for i = #positions, 1, -2 do
        for k = 1, 0, -1 do
            ops[#ops + 1] = { positions[i] + k + 1, positions[i - 1] + k + 1 }
        end
    end
    local chars = {}
    for i = 1, #b64 do
        chars[i] = b64:sub(i, i)
    end
    for i = #ops, 1, -1 do
        local a, b = ops[i][1], ops[i][2]
        chars[a], chars[b] = chars[b], chars[a]
    end
    local body = "x" .. table.concat(chars)
    local text, err = Protocol.decodeShards(md5(body):upper() .. body)
    Assert.is_nil(err)
    Assert.eq(text, plain)
end

-- decodeShards：合法分片 → hello
do
    -- 构造：对 base64("hello") 做与 reverseSwaps 相反的交换（len<11 → positions {0,2}）
    local b64 = "aGVsbG8="
    local chars = {}
    for i = 1, #b64 do
        chars[i] = b64:sub(i, i)
    end
    local function swap(i, j)
        chars[i], chars[j] = chars[j], chars[i]
    end
    swap(3, 1)
    swap(4, 2)
    local body = "x" .. table.concat(chars)
    local shard = md5(body):upper() .. body
    local text, err = Protocol.decodeShards(shard)
    Assert.is_nil(err)
    Assert.eq(text, "hello")
end

-- makeReadPayload：rt/ts/rn/sg 字段齐全
do
    local real_time, real_random = os.time, math.random
    os.time = function() return 1700000000 end
    math.random = function() return 42 end
    local payload = Protocol.makeReadPayload({
        book_id = "123",
        chapter_uid = "9",
        chapter_idx = 1,
        progress = 50,
        summary = "章节",
        psvts = "abc",
        elapsed_seconds = 30,
    })
    os.time = real_time
    math.random = real_random
    Assert.eq(payload.pr, 50)
    Assert.eq(payload.rt, 30)
    Assert.not_nil(payload.sg)
    Assert.not_nil(payload.s)
end
