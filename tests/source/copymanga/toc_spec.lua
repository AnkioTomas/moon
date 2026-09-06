--[[--
拷贝漫画目录缓存：uid ↔ idx 与全书 fraction。

@module tests.source.copymanga.toc_spec
--]]

local Assert = require("support.assert")

local store = {}
package.preload["db.book"] = function()
    return {
        getToc = function(source_id, stable_id)
            return store[source_id .. "\31" .. stable_id]
        end,
        setToc = function(source_id, stable_id, payload)
            store[source_id .. "\31" .. stable_id] = payload
            return true
        end,
    }
end
package.preload["json"] = function()
    return {
        decode = require("support.json_stub").decode,
        encode = require("support.json_stub").encode,
    }
end

package.loaded["source.copymanga.toc"] = nil
local Toc = require("source.copymanga.toc")

local list = {
    { idx = 1, uid = "u1", title = "第一话" },
    { idx = 2, uid = "u2", title = "第二话" },
    { idx = 3, uid = "u3", title = "第三话" },
}

do
    Assert.is_true(Toc.put("copymanga", "comic-a", list))
    Assert.eq(Toc.uid("copymanga", "comic-a", 2), "u2")
    Assert.eq(Toc.index("copymanga", "comic-a", "u3"), 3)
    Assert.is_nil(Toc.uid("copymanga", "comic-a", 99))
    Assert.is_nil(Toc.index("copymanga", "comic-a", "missing"))
    Assert.is_nil(Toc.index("copymanga", "comic-a", nil))
end

do
    Assert.eq(Toc.wholeFraction("copymanga", "comic-a", 1, 0), 0)
    Assert.eq(Toc.wholeFraction("copymanga", "comic-a", 2, 0), 1 / 3)
    Assert.eq(Toc.wholeFraction("copymanga", "comic-a", 3, 0.5), (2 + 0.5) / 3)
    Assert.is_nil(Toc.wholeFraction("copymanga", "missing", 1, 0))
end

do
    Toc.clear()
    Assert.eq(Toc.index("copymanga", "comic-a", "u1"), 1)
end
