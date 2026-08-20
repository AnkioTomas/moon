--[[-- book.stats：会话计时 / 翻页结清 --]]

local Assert = require("support.assert")

local added = {}
local deferred
package.preload["utils.db.stats"] = function()
    return {
        add = function(row)
            added[#added + 1] = row
            return true
        end,
    }
end
package.preload["utils.db.queue"] = function()
    return {
        run = function(worker, opts)
            if deferred then
                deferred = { worker = worker, opts = opts }
                return
            end
            local ok, err = pcall(worker)
            local cb = ok and opts and opts.on_done or opts and opts.on_failed
            if cb then cb(ok and nil or err) end
        end,
    }
end
package.loaded["book.stats"] = nil

-- 可控时钟（os.time 秒级精度，必须 mock 才能测 duration）
local real_time = os.time
local now = 100000
os.time = function()
    return now
end

local Tracker = require("book.stats")
local identity = { source_id = "moon", stable_id = "a.epub" }

local function ui(file, page, pages)
    return {
        ui = { document = { file = file } },
        identity = identity,
        page = page,
        total_pages = pages,
    }
end

-- stop 回调只能发生在最后一段成功落库之后。
do
    added = {}
    local u = ui("/book.epub", 3, 300)
    Tracker.start(u)
    now = now + 4
    local completed = false
    Tracker.stop(function(err)
        Assert.is_nil(err)
        completed = true
    end)
    Assert.eq(#added, 1)
    Assert.is_true(completed)
end

-- ── 正常会话：翻页结清旧页 + stop 结清当前页 ──────────
do
    added = {}
    local u = ui("/book.epub", 1, 300)
    Tracker.start(u)
    now = now + 10
    Tracker.onPage(ui("/book.epub", 2, 300))
    now = now + 20
    Tracker.stop()
    Assert.eq(#added, 2)
    Assert.eq(added[1].source_id, "moon")
    Assert.eq(added[1].stable_id, "a.epub")
    Assert.eq(added[1].page, 1)
    Assert.eq(added[1].duration, 10)
    Assert.eq(added[1].total_pages, 300)
    Assert.eq(added[2].page, 2)
    Assert.eq(added[2].duration, 20)
end

-- ── 过短停留（< 1s）丢弃 ─────────────────────────────
do
    added = {}
    local u = ui("/book.epub", 5, 300)
    Tracker.start(u)
    Tracker.stop()
    Assert.eq(#added, 0)
end

-- ── 重复 start 结清上一段；同页 onPage 忽略 ──────────
do
    added = {}
    local u = ui("/book.epub", 1, 300)
    Tracker.start(u)
    Tracker.onPage(ui("/book.epub", 1, 300))
    Assert.eq(#added, 0)
    now = now + 5
    Tracker.start(u)
    Assert.eq(#added, 1)
    Assert.eq(added[1].duration, 5)
    Tracker.stop()
    Assert.eq(#added, 1)
end

-- DB worker 延迟执行时仍必须记录翻页前的快照，不能读到已修改的会话表。
do
    added = {}
    local u = ui("/book.epub", 1, 300)
    Tracker.start(u)
    now = now + 5
    deferred = true
    Tracker.onPage(ui("/book.epub", 2, 300))
    local queued = deferred
    deferred = nil
    queued.worker()
    Assert.eq(added[1].page, 1)
    Assert.eq(added[1].duration, 5)
    Tracker.stop()
end

os.time = real_time

for _, name in ipairs({
    "utils.db.stats",
    "utils.db.queue",
    "book.stats",
}) do
    package.preload[name] = nil
    package.loaded[name] = nil
end
