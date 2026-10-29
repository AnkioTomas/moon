--[[--
章节源共用目录缓存：持久化、不做时间保鲜、源隔离。

@module tests.source.toc_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")
local now = 1000
local original_time = os.time
os.time = function() return now end

local rows = {}
local writes = true
local reads = 0
package.preload["book.books_db"] = function()
    return {
        getToc = function(source_id, stable_id, max_age)
            reads = reads + 1
            local row = rows[source_id .. ":" .. stable_id]
            if not row or (max_age and now - row.at >= max_age) then return nil end
            return row.payload, row.at
        end,
        setToc = function(source_id, stable_id, payload)
            if not writes then return false end
            rows[source_id .. ":" .. stable_id] = { payload = payload, at = now }
            return true
        end,
        clearToc = function(source_id, stable_id)
            rows[source_id .. ":" .. stable_id] = nil
        end,
    }
end
package.preload["json"] = function()
    return require("support.json_stub")
end

package.loaded["source.toc"] = nil
local Toc = require("source.toc")

local list = { { idx = 1, uid = "chapter-1" } }
writes = false
Assert.is_false(Toc.put("jdread", "book-1", list))
Assert.is_nil(Toc.read("jdread", "book-1"))

writes = true
Assert.is_true(Toc.put("jdread", "book-1", list))
Assert.eq(Toc.uid("jdread", "book-1", 1), "chapter-1")
Assert.is_nil(Toc.read("fanqie", "book-1"))
local before = reads
Assert.eq(Toc.index("jdread", "book-1", "chapter-1"), 1)
Assert.eq(reads, before)

do -- 有缓存就一直认：时间推进后仍可读（不再做 TTL 保鲜）
    Assert.is_true(Toc.put("subscribe", "9", { { idx = 1, uid = "g1" } }))
    now = now + 7 * 24 * 60 * 60
    Assert.eq(Toc.read("subscribe", "9")[1].uid, "g1")
    Assert.eq(Toc.uid("subscribe", "9", 1), "g1")
    Assert.eq(Toc.read("subscribe", "9", true)[1].uid, "g1", "旧 stale 参数仍兼容")
end

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
    Toc.clear()
    Assert.eq(Toc.uid("jdread", "drop", 1), "new")
end

do
    -- 进程内缓存超限清空后仍要放入新条目：库里有合法目录就必须读得到。
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

do
    -- 回填字数：内存立即可见，落库合并成一次延迟写（千章全本缓存不再序列化目录一千遍）。
    local Stubs = require("support.stubs")
    Stubs.reset()
    local saved = 0
    local setToc = package.loaded["book.books_db"].setToc
    package.loaded["book.books_db"].setToc = function(...)
        saved = saved + 1
        return setToc(...)
    end
    Assert.is_true(Toc.put("fanqie", "words", { { idx = 1, uid = "w1" }, { idx = 2, uid = "w2" } }))
    saved = 0
    Toc.setWords("fanqie", "words", 1, 1200)
    Toc.setWords("fanqie", "words", 2, 800)
    Toc.setWords("fanqie", "words", 2, 800)
    Assert.eq(Toc.read("fanqie", "words")[1].words, 1200, "内存目录立即带字数")
    Assert.eq(Toc.read("fanqie", "words")[2].words, 800)
    Assert.eq(saved, 0, "setWords 不同步写库")
    Stubs.flush()
    Assert.eq(saved, 1, "多次回填合并成一次写")
    local stored = require("json").decode(rows["fanqie:words"].payload)
    Assert.eq(stored[1].words, 1200)
    Assert.eq(stored[2].words, 800)

    -- 字数没变不排写；非法参数不碰库。
    Toc.setWords("fanqie", "words", 1, 1200)
    Toc.setWords("fanqie", "words", 1, 0)
    Toc.setWords("fanqie", "words", nil, 5)
    Toc.setWords("fanqie", "nope", 1, 5)
    Stubs.flush()
    Assert.eq(saved, 1)

    -- 等待落库期间目录被重新 put：新目录为准，过期的字数写不再覆盖它。
    Toc.setWords("fanqie", "words", 1, 1300)
    Assert.is_true(Toc.put("fanqie", "words", { { idx = 1, uid = "w1-new" } }))
    saved = 0
    Stubs.flush()
    Assert.eq(saved, 0)
    Assert.eq(Toc.uid("fanqie", "words", 1), "w1-new")

    -- 落库失败只告警，不抛。
    Toc.setWords("fanqie", "words", 1, 50)
    writes = false
    Stubs.flush()
    writes = true
    Assert.eq(Toc.read("fanqie", "words")[1].words, 50)
    package.loaded["book.books_db"].setToc = setToc
end

-- 缓存池被「many」用例冲掉后仍能从库读回；时间推进不导致 miss。
Toc.clear()
Assert.eq(Toc.read("jdread", "book-1")[1].uid, "chapter-1")
now = now + 6 * 60 * 60
Assert.eq(Toc.read("jdread", "book-1")[1].uid, "chapter-1", "目录不做时间保鲜")

do -- 开书拉新节流：成功看 fetched_at，失败看 last_attempt
    Toc.clear()
    Assert.is_true(Toc.allowRefresh("jdread", "book-1"), "间隔外允许拉新")
    Assert.is_false(Toc.allowRefresh("jdread", "book-1"), "同间隔内第二次拒绝（失败也记尝试）")
    now = now + Toc.REFRESH_INTERVAL + 1
    Assert.is_true(Toc.allowRefresh("jdread", "book-1"), "过了间隔再允许")
    Toc.clear()
    Assert.is_true(Toc.put("jdread", "throttle", { { idx = 1, uid = "t1" } }))
    Assert.is_false(Toc.allowRefresh("jdread", "throttle"), "刚 put 的目录不立刻再拉")
    Toc.drop("jdread", "throttle")
    Assert.is_true(Toc.allowRefresh("jdread", "throttle"), "drop 清掉尝试记录")
end

os.time = original_time
