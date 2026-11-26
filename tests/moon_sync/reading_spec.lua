--[[--
阅读数据：.po 确认之后脏标记清掉；笔记按设备分栏；本地书 extra 按内容合并。

@module tests.moon_sync.reading_spec
--]]

local Assert = require("support.assert")
package.preload["json"] = function()
    local JSON = require("support.json_stub")
    return { encode = JSON.encode, decode = JSON.decode }
end
package.loaded["json"] = nil

local Reading = require("moon_sync.reading")
local ProgressDB = require("book.progress_db")
local NoteDB = require("book.note_db")
local DB = require("utils.db")

local source_id = "moon-sync-reading"
ProgressDB.removeSource(source_id)
NoteDB.removeSource(source_id)

Assert.eq(Reading.fileName("book-1"), "book-1")
Assert.eq(Reading.idFromName(Reading.fileName("https://ex/a b")), "https://ex/a b")
Assert.is_nil(Reading.idFromName("bad%2"))
local encoded = Reading.fileName("https://ex/a b")
Assert.eq((encoded .. ".po"):match("^([%w%%%-]+)%.po$"), encoded)
Assert.eq(Reading.fileName(string.rep("a", 244)), string.rep("a", 244))
local long = string.rep("a", 245)
local hashed = Reading.fileName(long)
Assert.eq(#hashed, 34)
Assert.is_true(Reading.isDigest(hashed))
Assert.eq(Reading.fileName(long), hashed)
Assert.is_nil(Reading.idFromName(hashed))
Assert.eq(Reading.idOf(hashed, { [hashed] = long }), long)
Assert.eq((hashed .. ".json"):match("^([%w%%%-]+)%.json$"), hashed)
Assert.is_true(#hashed + #".cover.webp" <= 255)

local MoonSync = require("moon_sync")
local kindle_fb = MoonSync.fallbackOf(require("source.kindle").new())
Assert.is_true(kindle_fb.progress and kindle_fb.notes and kindle_fb.stats, "Kindle 三项都没有自己的接口")
local t18_fb = MoonSync.fallbackOf(require("source.18ta").new())
Assert.is_true(t18_fb.progress and t18_fb.notes and t18_fb.stats, "18ta 同样整份兜底")
local own = MoonSync.fallbackOf({
    putProgressAsync = function() end,
    pushNotesAsync = function() end,
    pushStatsAsync = function() end,
})
Assert.is_true(not own.progress and not own.notes and not own.stats, "三项都有接口的源不进月读同步")
local progress_only = MoonSync.fallbackOf({ putProgressAsync = function() end })
Assert.is_true(not progress_only.progress and progress_only.notes and progress_only.stats,
    "只同步进度的源，笔记和统计仍按同一套文件兜底")
local shelf_only = MoonSync.fallbackOf({ syncBooksAsync = function() end })
Assert.is_true(shelf_only.progress and shelf_only.notes and shelf_only.stats,
    "只有书架的源，进度、笔记和阅读记录都兜底")
Assert.is_true(Reading.shouldPull(nil, false, 10), "没有本地行就拉")
Assert.is_true(not Reading.shouldPull(10, true, 20), "脏行不拉")
Assert.is_true(not Reading.shouldPull(20, false, 20), "时间相同不拉")
Assert.is_true(Reading.shouldPull(10, false, 20))

ProgressDB.upsert(source_id, "book-1", { fraction = 0.2, chapter_idx = 3, updated_at = 50 })
local snap = ProgressDB.get(source_id, "book-1")
Assert.matches(Reading.progressLine(snap), "^50000%*3:20%.0%%$")
Reading.confirmProgress(source_id, snap)
local confirmed = ProgressDB.get(source_id, "book-1")
Assert.eq(confirmed.sync_status, 1, "推上去的进度标成已同步")
Assert.eq(confirmed.fraction, 0.2)

Assert.is_true(Reading.applyProgress(source_id, "book-1",
    Reading.progressLine({ fraction = 0.9, chapter_idx = 3, updated_at = 300 }), 300))
Assert.eq(ProgressDB.get(source_id, "book-1").fraction, 0.9, "干净行接受更新的 .po")

ProgressDB.upsert(source_id, "book-1", { fraction = 0.4, updated_at = 400 })
local during = ProgressDB.get(source_id, "book-1")
ProgressDB.upsert(source_id, "book-1", { fraction = 0.95, updated_at = 500 })
Reading.confirmProgress(source_id, during)
local raced = ProgressDB.get(source_id, "book-1")
Assert.eq(raced.sync_status, 0, "上传期间又改过的行保持脏")
Assert.eq(raced.fraction, 0.95)

Assert.matches(Reading.progressLine({ fraction = 0.5, chapter_idx = 0, page = 12, updated_at = 1 }),
    "^1000%*12@0#0:50%.0%%$", "没有字符偏移时页码写在章号的位置")

local kept = Reading.mergeDevice({ other = { { text = "theirs" } }, me = { { text = "old" } } }, "me", { { text = "mine" } })
Assert.eq(kept.other[1].text, "theirs")
Assert.eq(kept.me[1].text, "mine")

local note = require("json").encode({
    { page = "p", pos0 = "a", pos1 = "b", datetime = "t1", chapter_idx = 1, text = "local" },
})
NoteDB.upsert(source_id, "book-1", 1, note, 50)
local notes = Reading.notesByBook(source_id)
Reading.confirmNotes(source_id, notes["book-1"])
Assert.eq(NoteDB.get(source_id, "book-1", 1).sync_status, 1)
Reading.applyNotes(source_id, "book-1", {
    other = { { page = "p", pos0 = "a", pos1 = "b", datetime = "t2", chapter_idx = 1, text = "remote" } },
}, 80)
local decoded = require("book.note.normalize").decode(NoteDB.get(source_id, "book-1", 1).payload)
Assert.eq(decoded[1].text, "remote")

NoteDB.upsert(source_id, "book-1", 1, note, 90)
Reading.applyNotes(source_id, "book-1", {
    other = { { page = "p", pos0 = "a", pos1 = "b", datetime = "t3", chapter_idx = 1, text = "newer" } },
}, 100)
decoded = require("book.note.normalize").decode(NoteDB.get(source_id, "book-1", 1).payload)
Assert.eq(decoded[1].text, "local", "本地脏笔记不盖")

local StatsDB = require("book.stats_db")
DB.exec("DELETE FROM reading_stats WHERE source_id=?;", source_id)
StatsDB.add({
    source_id = source_id, stable_id = "book-1", record_type = "page",
    page = 1, start_time = 10, duration = 5,
}, StatsDB.PENDING)
local stat_books = Reading.statsByBook(source_id)
Assert.eq(#stat_books["book-1"].rows, 1)
Assert.eq(#stat_books["book-1"].dirty, 1)
Reading.applyStats(source_id, "book-1", {
    other = { { record_type = "page", page = 2, start_time = 20, duration = 6 } },
}, "me")
Reading.confirmStats(stat_books["book-1"].dirty)
Assert.eq(tonumber(DB.rowexec(
    "SELECT sync_status FROM reading_stats WHERE source_id=? AND stable_id=? AND page=1;",
    source_id, "book-1")), 1, "推上去的统计标成已同步")
Assert.eq(tonumber(DB.rowexec(
    "SELECT sync_status FROM reading_stats WHERE source_id=? AND stable_id=? AND page=2;",
    source_id, "book-1")), 1, "别的设备的统计写进来")

ProgressDB.removeIdentity("local", "audit-a")
ProgressDB.removeIdentity("local", "audit-b")
ProgressDB.upsertRemote("local", "audit-a", { fraction = 0.1, updated_at = 100, extra = { k = "old" } })
Assert.eq(Reading.applyLocalExtra({
    { stable_id = "audit-a", extra = '{"k":"new"}', updated_at = 200 },
    { stable_id = "audit-b", extra = '{"k":"gone"}', updated_at = 200 },
}), 1, "没有本地进度行的 extra 不新建")
local extra = ProgressDB.get("local", "audit-a")
Assert.eq(extra.extra.k, "new")
Assert.eq(extra.updated_at, 200, "extra 的修订号跟内容一起走")

ProgressDB.upsert("local", "audit-a", { fraction = 0.1, updated_at = 300, extra = { k = "mine" } })
Reading.applyLocalExtra({
    { stable_id = "audit-a", extra = '{"k":"theirs"}', updated_at = 400 },
})
Assert.eq(ProgressDB.get("local", "audit-a").extra.k, "mine", "本地脏 extra 不盖")

local merged = Reading.mergeLocalExtra({
    { stable_id = "audit-a", extra = '{"k":"same"}', updated_at = 300, sync_status = 1 },
    { stable_id = "audit-c", extra = '{"k":"local"}', updated_at = 50, sync_status = 0 },
    { stable_id = "audit-d", extra = '{"k":"stale"}', updated_at = 40, sync_status = 1 },
}, {
    { stable_id = "audit-a", extra = '{"k":"same"}', updated_at = 100 },
    { stable_id = "audit-b", extra = '{"k":"remote"}', updated_at = 80 },
    { stable_id = "audit-c", extra = '{"k":"other"}', updated_at = 200 },
    { stable_id = "audit-d", extra = '{"k":"fresh"}', updated_at = 90 },
})
local by_id = {}
for _idx, row in ipairs(merged) do
    Assert.is_nil(row.sync_status)
    by_id[row.stable_id] = row
end
Assert.eq(by_id["audit-a"].extra, '{"k":"same"}')
Assert.eq(by_id["audit-a"].updated_at, 300, "内容没变就只留较新的时间")
Assert.eq(by_id["audit-b"].extra, '{"k":"remote"}', "这台没有的书留在文件里")
Assert.eq(by_id["audit-c"].extra, '{"k":"local"}', "脏的 extra 比更新的远端优先")
Assert.eq(by_id["audit-c"].updated_at, 200)
Assert.eq(by_id["audit-d"].extra, '{"k":"fresh"}', "干净的旧 extra 让给远端")

ProgressDB.removeSource(source_id)
NoteDB.removeSource(source_id)
ProgressDB.removeIdentity("local", "audit-a")
ProgressDB.removeIdentity("local", "audit-b")
