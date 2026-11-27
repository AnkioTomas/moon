--[[-- 订阅清单同步：合并规则，以及写回后已读、摘要和删除墓碑。 --]]

local Assert = require("support.assert")

local function feed(url, title, changed, items, read_at)
    return { "rss", url, title, "", "", 0, read_at or 0, changed, items or {} }
end

local function item(guid, read, read_at, starred, star_at)
    return { guid, "t", "", 1, 1, read, read_at or 0, starred or 0, star_at or 0 }
end

local Sync = require("features.subscribe.sync")

-- 两边的源都合进去。
do
    local merged = Sync.merge(
        { { feed("https://a.example/rss", "A", 1) }, {} },
        { { feed("https://b.example/rss", "B", 1) }, {} })
    Assert.eq(#merged[1], 2)
    Assert.eq(merged[1][1][2], "https://a.example/rss")
    Assert.eq(merged[1][2][2], "https://b.example/rss")
end

-- 修订时间新的标题赢；一样新时按内容比，跟哪边是本地无关。
do
    local newer = Sync.merge(
        { { feed("https://a.example/rss", "old", 1) }, {} },
        { { feed("https://a.example/rss", "new", 4) }, {} })
    Assert.eq(newer[1][1][3], "new")
    local left = Sync.merge(
        { { feed("https://a.example/rss", "m", 5) }, {} },
        { { feed("https://a.example/rss", "a", 5) }, {} })
    local right = Sync.merge(
        { { feed("https://a.example/rss", "a", 5) }, {} },
        { { feed("https://a.example/rss", "m", 5) }, {} })
    Assert.eq(left[1][1][3], "m")
    Assert.eq(right[1][1][3], "m")
end

-- 墓碑不比修订旧就删；重新改过的源留着，墓碑丢掉。
do
    local dropped = Sync.merge(
        { { feed("https://a.example/rss", "A", 5) }, {} },
        { {}, { { "rss", "https://a.example/rss", 5 } } })
    Assert.eq(#dropped[1], 0)
    Assert.eq(dropped[2][1][2], "https://a.example/rss")
    local kept = Sync.merge(
        { { feed("https://a.example/rss", "A", 6) }, {} },
        { {}, { { "rss", "https://a.example/rss", 5 } } })
    Assert.eq(#kept[1], 1)
    Assert.eq(#kept[2], 0)
end

-- 已读只增不减；收藏以后改的为准。
do
    local merged = Sync.merge(
        { { feed("https://a.example/rss", "A", 1, { item("g", 1, 9, 1, 4) }) }, {} },
        { { feed("https://a.example/rss", "A", 1, { item("g", 0, 3, 0, 8), item("h", 0, 0, 0, 0) }) }, {} })
    local items = merged[1][1][9]
    Assert.eq(items[1][1], "g")
    Assert.eq(items[1][6], 1, "已读留下")
    Assert.eq(items[1][7], 9)
    Assert.eq(items[1][8], 0, "后取消的收藏赢")
    Assert.eq(items[1][9], 8)
    Assert.eq(items[2][1], "h")
end

if not pcall(require, "lua-ljsqlite3/init") then return true end

local Config = require("support.config")
local db_path = Config.dir() .. "/subscribe_sync_spec.sqlite3"
for _idx, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(db_path .. suffix) end
package.loaded["utils.paths"] = nil
package.preload["utils.paths"] = function()
    return { dbPath = function() return db_path end, ensureSettings = function() end }
end
for _idx, name in ipairs({ "utils.db", "features.subscribe.db", "features.subscribe.sync" }) do
    package.loaded[name] = nil
end
local DB = require("utils.db")
local SubDB = require("features.subscribe.db")
Sync = require("features.subscribe.sync")
Assert.not_nil(DB.open())

local id = SubDB.add({ kind = "rss", url = "https://a.example/rss", title = "A", grp = "新闻" })
Assert.not_nil(id)
DB.exec("UPDATE sub_feeds SET changed_at=10 WHERE id=?;", id)
SubDB.update(id, { cursor = 4, updated_at = 20, error = "x" })
Assert.eq(tonumber(DB.rowexec("SELECT changed_at FROM sub_feeds WHERE id=?;", id)), 10, "刷新不改修订时间")
SubDB.update(id, { title = "A2" })
Assert.is_true(tonumber(DB.rowexec("SELECT changed_at FROM sub_feeds WHERE id=?;", id)) > 10, "改标题才改修订时间")

DB.exec("UPDATE sub_feeds SET changed_at=10 WHERE id=?;", id)
SubDB.merge(id, { { guid = "g1", title = "一条", summary = "<p>正文</p>", time = os.time() } })
SubDB.markRead(id, "g1", 30)
Assert.eq(SubDB.summary(id, "g1"), "<p>正文</p>", "合并后摘要在")

-- 旧文档不盖本地标题；摘要不进文档，写回后还在。已读留下。
local old = Sync.merge(Sync.export(), {
    { feed("https://a.example/rss", "外来", 1, { item("g1", 0, 0, 0, 0) }, 0) },
    {},
})
Assert.is_true(SubDB.applySync(Sync.unpack(old)))
Assert.eq(SubDB.feed(id).title, "A2")
Assert.eq(SubDB.summary(id, "g1"), "<p>正文</p>")
local items = SubDB.items(id, 1, 10)
Assert.eq(items[1].read, true)

-- 更新的文档改标题，并带进另一台才有的源。
local remote = Sync.merge(Sync.export(), {
    {
        feed("https://a.example/rss", "新标题", 999, { item("g1", 1, 40, 0, 0) }, 80),
        feed("https://b.example/rss", "B", 4),
    },
    {},
})
Assert.is_true(SubDB.applySync(Sync.unpack(remote)))
Assert.eq(SubDB.feed(id).title, "新标题")
Assert.eq(SubDB.feed(id).read_at, 80)
Assert.eq(SubDB.summary(id, "g1"), "<p>正文</p>", "摘要仍不覆盖")
local other = DB.rowexec("SELECT id FROM sub_feeds WHERE url=?;", "https://b.example/rss")
Assert.not_nil(other)

-- 墓碑盖过修订：源删掉，重新订阅再清掉墓碑。
package.loaded["features.subscribe"] = {
    remove = function(feed) SubDB.remove(feed.id) end,
}
DB.exec("UPDATE sub_feeds SET changed_at=10 WHERE url=?;", "https://a.example/rss")
local doomed = Sync.merge(Sync.export(), { {}, { { "rss", "https://a.example/rss", 50 } } })
Assert.is_true(Sync.import(doomed))
Assert.is_nil(DB.rowexec("SELECT id FROM sub_feeds WHERE url=?;", "https://a.example/rss"))
Assert.eq(tonumber(DB.rowexec("SELECT at FROM sub_removed WHERE url=?;", "https://a.example/rss")) >= 50, true)
local again = SubDB.add({ kind = "rss", url = "https://a.example/rss", title = "回来了" })
Assert.not_nil(again)
Assert.is_nil(DB.rowexec("SELECT at FROM sub_removed WHERE url=?;", "https://a.example/rss"))

return true
