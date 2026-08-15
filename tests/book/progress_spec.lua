--[[--
book.progress flushPending 离线用例（stub ProgressDB / UI）

@module tests.book.progress_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")

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

package.preload["utils.db.progress"] = function()
    return {
        all = function(source_id)
            local out = {}
            for _, r in ipairs(pending) do
                if r.source_id == source_id then
                    out[#out + 1] = r
                end
            end
            return out
        end,
        delete = function(source_id, stable_id)
            deleted[#deleted + 1] = source_id .. ":" .. stable_id
            return true
        end,
        upsert = function()
            return true
        end,
    }
end

package.preload["utils.db.queue"] = function()
    return {
        run = function(worker, opts)
            -- 测试环境同步执行 worker（无 write_fd），然后回调 on_done
            worker(nil)
            if opts and opts.on_done then
                opts.on_done(nil)
            end
        end,
        clear = function() end,
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
package.loaded["utils.db.progress"] = nil
package.loaded["ui/widget/infomessage"] = nil
package.loaded["source.contract"] = nil

local Progress = require("book.progress")

local pushed = {}
local source = {
    id = "moon",
    putProgress = function(_, ref, pos)
        pushed[#pushed + 1] = { ref.stable_id, pos.fraction }
        return { cancel = function() end }
    end,
}

source.putProgressAsync = function(_, ref, pos, cb)
    pushed[#pushed + 1] = { ref.stable_id, pos.fraction }
    cb(true)
    return { cancel = function() end }
end

local n
Progress.flushPendingAsync(source, false, function(count)
    n = count
end)
Stubs.flush()
Assert.eq(n, 2)
Assert.eq(#pushed, 2)
Assert.eq(pushed[1][1], "a.epub")
Assert.eq(#deleted, 2)

local no_push
Progress.flushPendingAsync({
    id = "moon",
}, false, function(count)
    no_push = count
end)
Assert.eq(no_push, 0)

for _, k in ipairs({
    "utils.db.progress",
    "ui/widget/infomessage",
    "ui/event",
    "ui/network/manager",
    "book.store",
    "book.progress",
}) do
    package.preload[k] = nil
    package.loaded[k] = nil
end
