--[[-- stats.tracker：会话计时 / 翻页结清 / 非源书跳过 --]]

local Assert = require("support.assert")

local added = {}
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
        run = function(worker)
            worker()
        end,
    }
end
package.preload["book.store"] = function()
    return {
        identityFor = function(path)
            if path == "/local.epub" then
                return nil
            end
            return {
                ref = { source_id = "moon", stable_id = "a.epub" },
            }
        end,
    }
end
package.loaded["stats.tracker"] = nil

-- 可控时钟（os.time 秒级精度，必须 mock 才能测 duration）
local real_time = os.time
local now = 100000
os.time = function()
    return now
end

local Tracker = require("stats.tracker")

local function ui(file, page, pages)
    return {
        document = {
            file = file,
            getPageCount = function()
                return pages
            end,
        },
        getCurrentPage = function()
            return page
        end,
    }
end

-- ── 非源书不统计 ─────────────────────────────────────
do
    Tracker.start(ui("/local.epub", 1, 100))
    Assert.is_nil(Tracker._cur)
    Tracker.onPage(ui("/local.epub", 2, 100), 2)
    Tracker.stop()
    Assert.eq(#added, 0)
end

-- ── 正常会话：翻页结清旧页 + stop 结清当前页 ──────────
do
    local u = ui("/book.epub", 1, 300)
    Tracker.start(u)
    now = now + 10
    Tracker.onPage(u, 2)
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
    Tracker.onPage(u, 1)
    Assert.eq(#added, 0)
    now = now + 5
    Tracker.start(u)
    Assert.eq(#added, 1)
    Assert.eq(added[1].duration, 5)
    Tracker.stop()
    Assert.eq(#added, 1)
end

os.time = real_time

for _, name in ipairs({
    "utils.db.stats",
    "utils.db.queue",
    "book.store",
    "stats.tracker",
}) do
    package.preload[name] = nil
    package.loaded[name] = nil
end
