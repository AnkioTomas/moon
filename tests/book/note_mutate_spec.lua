--[[--
book.note：条目键、改备注、删除时走源侧墓碑，以及打开中的章节会被同步改写。

@module tests.book.note_mutate_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")
local Config = require("support.config")

local JSON = require("support.json_stub")
package.loaded["json"] = JSON
package.preload["json"] = function() return JSON end

local sqlite_ok = pcall(require, "lua-ljsqlite3/init")
if not sqlite_ok then
    Assert.skip("当前离线环境没有 ljsqlite3 Lua 模块")
end

local db_path = Config.dir() .. "/note_mutate_spec.sqlite3"
for _idx, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(db_path .. suffix) end

package.loaded["utils.paths"] = nil
package.preload["utils.paths"] = function()
    return {
        dbPath = function() return db_path end,
        ensureSettings = function() end,
    }
end
package.loaded["ui/network/manager"] = { isConnected = function() return false end }

local live = {
    annotations = {
        {
            datetime = "2026-11-01 10:00:00", drawer = "lighten", color = "yellow",
            text = "打开中的句子", note = "旧备注",
            page = "/body/p[1]/text()[1].0", pos0 = "/body/p[1]/text()[1].0",
            pos1 = "/body/p[1]/text()[1].6",
        },
    },
}
live.annotation = live
function live.updateAnnotations() live.updated = true end
live.doc_settings = {
    saveSetting = function(_, key, value) live.saved = { key, value } end,
    flush = function() live.flushed = true end,
}
package.loaded["apps/reader/readerui"] = { instance = live }
package.loaded["reader.session"] = {
    _snapshot = { identity = { source_id = "local", stable_id = "open-book", chapter_idx = 2 } },
}

local wechat_notes = require("source.wechat.notes")
local function kavitaPrepare(_, previous, current, deleted)
    -- 与 source.kavita.prepareLocalAnnotations 的删除墓碑契约一致（见 init.lua）。
    if type(deleted) == "table" and deleted.pos0 then
        for _idx, old in ipairs(previous or {}) do
            if old.pos0 == deleted.pos0 and old.kavita_id then
                current[#current + 1] = {
                    datetime = old.datetime, chapter_idx = old.chapter_idx,
                    kavita_id = old.kavita_id, kavita_note = old.kavita_note, kavita_deleted = true,
                }
            end
        end
    end
    return current
end

package.loaded["source.registry"] = {
    resolve = function(id)
        if id == "wechat" then
            return {
                id = "wechat",
                cleanAnnotations = wechat_notes.cleanAnnotations,
                prepareLocalAnnotations = function(_, prev, cur)
                    return wechat_notes.prepareLocalAnnotations(prev, cur)
                end,
            }
        end
        if id == "kavita" then
            return {
                id = "kavita",
                cleanAnnotations = function(_, items, total)
                    return require("book.note.normalize").clean(items, total)
                end,
                prepareLocalAnnotations = kavitaPrepare,
            }
        end
        return { id = id }
    end,
}

for _idx, name in ipairs({ "utils.db", "book.books_db", "book.note_db", "book.note" }) do
    package.loaded[name] = nil
end

local Base = require("utils.db")
local NoteDB = require("book.note_db")
local Note = require("book.note")
local Normalize = require("book.note.normalize")
Assert.not_nil(Base.open())

local function item(extra)
    local it = {
        datetime = "2026-11-01 10:00:00",
        drawer = "lighten",
        color = "yellow",
        text = "一段原文",
        page = "/body/p[1]/text()[1].0",
        pos0 = "/body/p[1]/text()[1].0",
        pos1 = "/body/p[1]/text()[1].6",
        chapter = "第一章",
        chapter_idx = 1,
    }
    for k, v in pairs(extra or {}) do it[k] = v end
    return it
end

local function save(source_id, stable_id, chapter_idx, items, synced)
    Assert.is_true(NoteDB.upsert(source_id, stable_id, chapter_idx, JSON.encode(items), 100, synced))
end

-- 键可往返，分页 pos 表不会因地址误撞。
local a = item({ pos0 = { page = 3, x = 1, y = 2 }, pos1 = { page = 3, x = 9, y = 2 }, page = 3 })
local key = Note.itemKey("moon", "book", 0, a)
local parsed = Note.parseItemKey(key)
Assert.not_nil(parsed)
Assert.eq(parsed.source_id, "moon")
Assert.eq(parsed.stable_id, "book")
Assert.eq(parsed.chapter_idx, 0)
Assert.eq(Note.itemKey("moon", "book", 0, a), key)
Assert.is_nil(Note.parseItemKey(""))
Assert.is_nil(Note.parseItemKey("%%%"))

-- 改备注：只动 note，不动 text / 位置。
save("local", "book-a", 1, { item({ note = "旧" }) })
local edit_key = Note.itemKey("local", "book-a", 1, item({ note = "旧" }))
Assert.is_true(Note.mutate({ key = edit_key, note = "  新备注  " }))
local row = NoteDB.get("local", "book-a", 1)
local got = Normalize.decode(row.payload)
Assert.eq(got[1].note, "新备注")
Assert.eq(got[1].text, "一段原文")
Assert.eq(got[1].pos0, "/body/p[1]/text()[1].0")
Assert.eq(row.sync_status, 0)

-- 清空备注。
Assert.is_true(Note.mutate({ key = edit_key, note = "   " }))
got = Normalize.decode(NoteDB.get("local", "book-a", 1).payload)
Assert.is_nil(got[1].note)

-- 微信：删除带 bookmark id 的划线必须留下 wr_deleted 墓碑，不能只从快照抹掉。
local wr = item({ wr_bookmark_id = "bm-1", wr_range = "10-20", text = "微信句子" })
save("wechat", "wr-book", 3, { wr })
local wr_key = Note.itemKey("wechat", "wr-book", 3, wr)
Assert.is_true(Note.mutate({ key = wr_key, remove = true }))
local wr_items = Normalize.decode(NoteDB.get("wechat", "wr-book", 3).payload)
local tombs, visible = 0, 0
for _idx, it in ipairs(wr_items) do
    if it.wr_deleted then
        tombs = tombs + 1
        Assert.eq(it.wr_bookmark_id, "bm-1")
    else
        visible = visible + 1
    end
end
Assert.eq(tombs, 1)
Assert.eq(visible, 0)

-- Kavita：删除必须把 deleted 交给 prepareLocalAnnotations，写出 kavita_deleted 墓碑。
local kv = item({ kavita_id = 42, kavita_note = "k", text = "Kavita 句子", pos0 = "/body/p[2]/text()[1].0" })
save("kavita", "kv-book", 0, { kv }, true)
local kv_key = Note.itemKey("kavita", "kv-book", 0, kv)
Assert.is_true(Note.mutate({ key = kv_key, remove = true }))
local kv_items = Normalize.decode(NoteDB.get("kavita", "kv-book", 0).payload)
local kv_tomb = 0
for _idx, it in ipairs(kv_items) do
    if it.kavita_deleted then
        kv_tomb = kv_tomb + 1
        Assert.eq(it.kavita_id, 42)
    end
end
Assert.eq(kv_tomb, 1)

-- 属主源已不可用：不允许通用清洗抹掉源字段、删除墓碑和原有同步状态。
do
    local Registry = require("source.registry")
    local resolve = Registry.resolve
    local pending = { datetime = wr.datetime, wr_bookmark_id = "pending", wr_deleted = true }
    save("wechat", "unavailable", 0, { wr, pending }, true)
    local before = NoteDB.get("wechat", "unavailable", 0)
    Registry.resolve = function() return nil, "source unavailable" end
    local unavailable_key = Note.itemKey("wechat", "unavailable", 0, wr)
    for _idx, opts in ipairs({
        { key = unavailable_key, note = "不能保存" },
        { key = unavailable_key, remove = true },
    }) do
        local changed, change_err = Note.mutate(opts)
        Assert.is_false(changed)
        Assert.eq(change_err, "source unavailable")
        local after = NoteDB.get("wechat", "unavailable", 0)
        Assert.eq(after.payload, before.payload)
        Assert.eq(after.updated_at, before.updated_at)
        Assert.eq(after.sync_status, before.sync_status)
    end
    Registry.resolve = resolve
end

-- 当前正打开的章节：改备注会写进阅读器内存和 sidecar，避免下次保存盖掉。
local open_item = item({
    text = "打开中的句子", note = "旧备注",
    page = "/body/p[1]/text()[1].0",
    pos0 = "/body/p[1]/text()[1].0",
    pos1 = "/body/p[1]/text()[1].6",
})
save("local", "open-book", 2, { open_item })
local open_key = Note.itemKey("local", "open-book", 2, open_item)
Assert.is_true(Note.mutate({ key = open_key, note = "  远程改的  " }))
Assert.eq(live.annotations[1].note, "远程改的")
Assert.eq(Normalize.decode(NoteDB.get("local", "open-book", 2).payload)[1].note, live.annotations[1].note)
Assert.is_true(live.updated)
Assert.is_true(live.flushed)
Assert.eq(live.saved[1], "annotations")

Assert.is_true(Note.mutate({ key = open_key, remove = true }))
Assert.eq(#live.annotations, 0)

-- 找不到的键：格式错误，或书不存在。
local ok, err = Note.mutate({ key = "%%%", note = "x" })
Assert.is_false(ok)
Assert.eq(err, "invalid key")
ok, err = Note.mutate({ key = Note.itemKey("local", "missing", 0, item()), remove = true })
Assert.is_false(ok)
Assert.eq(err, "not found")

Base.close()
for _idx, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(db_path .. suffix) end
