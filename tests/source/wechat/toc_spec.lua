--[[--
source.wechat.toc：目录缓存读取与按 idx/uid 定位。 --]]

local Assert = require("support.assert")

local store = {}
local upserted = {}
local reads = 0
package.preload["db.book"] = function()
    return {
        getToc = function(_source_id, stable_id)
            reads = reads + 1
            return store[stable_id]
        end,
        setToc = function(_source_id, stable_id, payload)
            upserted[stable_id] = payload
        end,
    }
end
package.preload["json"] = function()
    return {
        decode = require("support.json_stub").decode,
        encode = function(value) return "encoded:" .. tostring(#value) end,
    }
end

package.loaded["source.wechat.toc"] = nil
local Toc = require("source.wechat.toc")

do
    Assert.is_nil(Toc.read("wechat", "missing"))
    Assert.is_nil(Toc.read("wechat", "broken"))
end

do
    -- payload 是目录数组（与 Mapper.chapters 输出一致），按数组索引定位。
    store["b2"] = [[
        [{"idx":1,"uid":"u1"},{"idx":2,"uid":"u2"}]
    ]]
    Assert.eq(Toc.uid("wechat", "b2", 1), "u1")
    Assert.eq(Toc.uid("wechat", "b2", 2), "u2")
    Assert.is_nil(Toc.uid("wechat", "b2", 99))
    Assert.eq(Toc.index("wechat", "b2", "u2"), 2)
    Assert.is_nil(Toc.index("wechat", "b2", "u9"))
end

do
    -- 解码结果进内存：库里的行没了也照样命中，翻页/按章补报不再反复 decode 整份目录。
    local before = reads
    store["b2"] = nil
    Assert.eq(Toc.uid("wechat", "b2", 1), "u1")
    Assert.eq(Toc.index("wechat", "b2", "u2"), 2)
    Assert.eq(reads, before, "命中内存缓存时不得再查库")

    -- clear 后回落到库（此时库里已无数据）
    Toc.clear()
    Assert.is_nil(Toc.read("wechat", "b2"))
    Assert.is_true(reads > before)
end

do
    -- put 落库并直接接管缓存，无需再 decode 一遍
    local list = { { idx = 1, uid = "p1" }, { idx = 2, uid = "p2" }, { idx = 3, uid = "p3" } }
    Toc.put("wechat", "b3", list)
    Assert.eq(upserted["b3"], "encoded:3")
    local before = reads
    Assert.eq(Toc.uid("wechat", "b3", 3), "p3")
    Assert.eq(Toc.index("wechat", "b3", "p2"), 2)
    Assert.eq(reads, before)

    -- 章内进度 + 章节序号 → 全书 fraction
    Assert.eq(Toc.wholeFraction("wechat", "b3", 1, 0), 0)
    Assert.eq(Toc.wholeFraction("wechat", "b3", 2, 0.5), 0.5)
    Assert.eq(Toc.wholeFraction("wechat", "b3", 3, 1), 1)
    Assert.is_nil(Toc.wholeFraction("wechat", "unknown", 1, 0))
end
