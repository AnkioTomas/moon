--[[--
京东/番茄共用目录缓存：持久化、TTL 与源隔离。

@module tests.source.jdread.toc_spec
--]]

local Assert = require("support.assert")
local now = 1000
local original_time = os.time
os.time = function() return now end

local rows = {}
local writes = true
local reads = 0
package.preload["db.book"] = function()
    return {
        getToc = function(source_id, stable_id, max_age)
            reads = reads + 1
            local row = rows[source_id .. ":" .. stable_id]
            if not row or now - row.at >= max_age then return nil end
            return row.payload, row.at
        end,
        setToc = function(source_id, stable_id, payload)
            if not writes then return false end
            rows[source_id .. ":" .. stable_id] = { payload = payload, at = now }
            return true
        end,
    }
end
package.preload["json"] = function()
    return require("support.json_stub")
end

package.loaded["source.jdread.toc"] = nil
package.loaded["source.fanqie.toc"] = nil
local Toc = require("source.jdread.toc")
local FanqieToc = require("source.fanqie.toc")
Assert.eq(Toc, FanqieToc)

local list = { { idx = 1, uid = "chapter-1" } }
writes = false
Assert.is_false(Toc.put("jdread", "book-1", list))
Assert.is_nil(Toc.read("jdread", "book-1"))

writes = true
Assert.is_true(Toc.put("jdread", "book-1", list))
Assert.eq(FanqieToc.uid("jdread", "book-1", 1), "chapter-1")
Assert.is_nil(FanqieToc.read("fanqie", "book-1"))
local before = reads
Assert.eq(Toc.index("jdread", "book-1", "chapter-1"), 1)
Assert.eq(reads, before)

do
    local list = {
        { idx = 1, uid = "u1" },
        { idx = 2, uid = "u2" },
        { idx = 3, uid = "u3" },
    }
    Assert.is_true(Toc.put("jdread", "frac", list))
    Assert.eq(Toc.wholeFraction("jdread", "frac", 1, 0), 0)
    Assert.eq(Toc.wholeFraction("jdread", "frac", 2, 0), 1 / 3)
    Assert.eq(Toc.wholeFraction("jdread", "frac", 3, 0.5), (2 + 0.5) / 3)
    Assert.is_nil(Toc.wholeFraction("jdread", "missing", 1, 0))
end

do
    Assert.is_true(Toc.put("jdread", "drop", { { idx = 1, uid = "old" } }))
    Assert.eq(Toc.uid("jdread", "drop", 1), "old")
    rows["jdread:drop"] = {
        payload = require("json").encode({ { idx = 1, uid = "new" } }),
        at = now,
    }
    Toc.invalidate("jdread", "drop")
    Assert.eq(Toc.uid("jdread", "drop", 1), "new")
end

do
    -- 进程内缓存超限淘汰不得淘汰刚写入的条目：库里有合法目录就必须读得到。
    for i = 1, 80 do
        local id = "many-" .. i
        rows["fanqie:" .. id] = {
            payload = require("json").encode({ { idx = 1, uid = id } }),
            at = now,
        }
        Assert.eq(Toc.uid("fanqie", id, 1), id)
        Assert.eq(Toc.index("fanqie", id, id), 1)
    end
end

now = now + 6 * 60 * 60
Assert.is_nil(Toc.read("jdread", "book-1"))
Assert.is_true(reads > before)

os.time = original_time
