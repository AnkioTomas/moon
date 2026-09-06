--[[--
京东读书 PC1 与双 MD5 签名离线用例。

@module tests.source.jdread.protocol_spec
--]]

local Assert = require("support.assert")

package.preload["json"] = function()
    return {
        decode = require("support.json_stub").decode,
        encode = require("support.json_stub").encode,
    }
end
package.loaded["json"] = nil
package.loaded["source.jdread.protocol"] = nil

local Protocol = require("source.jdread.protocol")

do
    local params = Protocol.signedParams(
        "/jdread/api/marker/sync",
        "h500000000000000000000000000000000",
        nil,
        1700000000123
    )
    Assert.eq(params.sign, "6f219d40caff3860cb21cebbfb9ce5c7")
end

do
    Assert.eq(
        Protocol.bookKey("30451107"),
        "c32bc1eceb889c09e2ddfef0a560db3b6a9f56f2e29ac481d18c79a0e1105461"
            .. "6b63f49c37217c79ac48eca85de9259ec576f4c72b2261b82bb9f5ec0555df691686"
    )
    Assert.eq(
        Protocol.chapterKey("30451107", "56958326"),
        "c32bc1eceb889c09e2ddfef0a560db3b6a9f56f2e29ac481d18c79a0e1105461"
            .. "6b63f49c37217c79ac48eca85de9259ec576f4c72b2261b82bb9f5ec0555df6916"
            .. "d7c72957bf46966ed4cbc3e24f3f3f7e62f7ec95a464e60a4fcfb8ea3ccd6bd786a292ca4475cab9e6cb71044b458d"
    )
end

do
    local encrypted = "c32bc1eceb8e4eb056d5b8a7d4f1364b8002d5be2221b2d1091849521f3f0e61"
        .. "e87fe3732e39f5a5d2d943903288ff99b1da063b53b9c4f1039cc3e83dd3c901"
        .. "6810849a03a75fac5dc7ddb96657b74564acb8f7ef959365953965b8ff4b4bb5c"
        .. "14eae0f9629c99df08aeb7e"
    local wire, err = Protocol.decodeEnvelope(
        '{"code":"0","content":"' .. encrypted .. '"}'
    )
    Assert.is_nil(err)
    Assert.eq(wire.catalogList[1].catalogName, "章节😀")
    Assert.eq(wire.catalogList[1].catalogId, 7)
end

do
    local wire, err, retryable = Protocol.decodeEnvelope('{"code":"-1","msg":"未购买"}')
    Assert.is_nil(wire)
    Assert.eq(err, "未购买")
    Assert.is_true(retryable)
end
