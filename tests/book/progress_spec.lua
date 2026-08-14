--[[--
book.progress flushPending 离线用例（stub Db / UI）

@module tests.book.progress_spec
--]]

local Assert = require("support.assert")

local pending = {
    {
        source_id = "moon",
        stable_id = "a.epub",
        fraction = 0.4,
        updated_at = 1,
    },
    {
        source_id = "moon",
        stable_id = "b.epub",
        fraction = 0.9,
        updated_at = 2,
    },
}
local deleted = {}

package.preload["utils.db"] = function()
    return {
        allPendingProgress = function(source_id)
            local out = {}
            for _, r in ipairs(pending) do
                if r.source_id == source_id then
                    out[#out + 1] = r
                end
            end
            return out
        end,
        deletePendingProgress = function(source_id, stable_id)
            deleted[#deleted + 1] = source_id .. ":" .. stable_id
            return true
        end,
        upsertPendingProgress = function()
            return true
        end,
    }
end

package.preload["ui/widget/infomessage"] = function()
    return { new = function() return {} end }
end
package.preload["ui/event"] = function()
    return { new = function() return {} end }
end
package.preload["ui/network/manager"] = function()
    return {
        runWhenOnline = function(_, fn)
            fn()
        end,
    }
end
package.preload["book.store"] = function()
    return {
        identityFor = function() return nil end,
    }
end

package.loaded["book.progress"] = nil
package.loaded["utils.db"] = nil
package.loaded["ui/widget/infomessage"] = nil
package.loaded["source.contract"] = nil

local Progress = require("book.progress")

local pushed = {}
local source = {
    id = "moon",
    capabilities = function()
        return { progress_push = true, progress_pull = true }
    end,
    putProgress = function(_, ref, pos)
        pushed[#pushed + 1] = { ref.stable_id, pos.fraction }
        return true
    end,
}

local n = Progress.flushPending(source, false)
Assert.eq(n, 2)
Assert.eq(#pushed, 2)
Assert.eq(pushed[1][1], "a.epub")
Assert.eq(#deleted, 2)

Assert.eq(Progress.flushPending({
    id = "moon",
    capabilities = function()
        return { progress_push = false }
    end,
}, false), 0)

for _, k in ipairs({
    "utils.db",
    "ui/widget/infomessage",
    "ui/event",
    "ui/network/manager",
    "book.store",
    "book.progress",
}) do
    package.preload[k] = nil
    package.loaded[k] = nil
end
