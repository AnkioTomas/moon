--[[--
换账号保留本地书籍与阅读记录；加架上行、只读下架及迟到确认隔离。

@module tests.source.account_switch_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
local Config = require("support.config")
package.loaded["json"] = require("support.json_stub")
local DB = require("utils.db")
local BookDB = require("book.books_db")
local ProgressDB = require("book.progress_db")
local NoteDB = require("book.note_db")
local StatsDB = require("book.stats_db")
local Auth = require("source.auth")
local Base = require("source.base")
local Shelf = require("source.shelf")
local sources = {}
package.loaded["source.registry"] = {
    resolve = function(id) return sources[id] end,
    invalidate = function() end,
    reload = function() end,
}
package.loaded["reader.session"] = { current = function() end }
local Logout = require("source.logout")

local function fixture(id, shelf_add)
    Assert.is_true(BookDB.forgetSource(id))
    local source = setmetatable({ id = id, shelf_add = shelf_add }, { __index = Base })
    sources[id] = source
    for _idx, stable_id in ipairs({ "keep", "missing", "tombstone", "never-read" }) do
        Assert.is_true(BookDB.upsertRemote({
            source_id = id, stable_id = stable_id, title = stable_id,
            deleted = 0, path = Config.dir() .. "/" .. id .. "-" .. stable_id .. ".epub",
        }))
    end
    Assert.is_true(BookDB.setLibraryMembership(id, "tombstone", false))
    for _idx, stable_id in ipairs({ "keep", "missing", "tombstone" }) do
        Assert.is_true(ProgressDB.upsertRemote(id, stable_id, {
            fraction = 0.63, chapter_idx = 8, updated_at = 123,
        }))
    end
    Assert.is_true(ProgressDB.upsertRemote(id, "never-read", { fraction = 0, updated_at = 0 }))
    Assert.is_true(NoteDB.upsert(id, "keep", nil, '[{"text":"保留划线"}]', 123, true))
    Assert.is_true(NoteDB.upsert(id, "never-read", nil, "[]", 123))
    Assert.is_true(StatsDB.add({
        source_id = id, stable_id = "keep", record_type = "page",
        page = 8, total_pages = 100, start_time = 100, duration = 30,
    }, StatsDB.SYNCED))
    Assert.is_true(StatsDB.add({
        source_id = id, stable_id = "keep", record_type = "page",
        page = 9, total_pages = 100, start_time = 200, duration = 20,
    }, StatsDB.IMPORTED))
    Assert.is_true(StatsDB.add({
        source_id = id, stable_id = "__total", record_type = "total",
        start_time = 300, duration = 300, page = 0, total_pages = 0,
    }, StatsDB.SYNCED))
    return source
end

-- 不支持加架的源只按完整、非空快照下架；记录和可读缓存不删。
do
    local source = fixture("account-readonly", false)
    Assert.is_true(ProgressDB.setDecisionPending(source.id, "missing", true))
    local committed = false
    Assert.is_true(Logout.replaceLibrary(source.id, function() committed = true end))
    Assert.is_true(committed)
    Assert.len(BookDB.pendingShelfAddIds(source.id), 0)
    Assert.len(BookDB.pendingDeleteIds(source.id), 0, "旧账号待删记录不得推到新账号")
    Assert.eq(BookDB.get(source.id, "missing").deleted, 0, "换账号当场不能清书架")
    Assert.eq(ProgressDB.get(source.id, "missing").fraction, 0.63)
    Assert.eq(ProgressDB.get(source.id, "missing").updated_at, 123)
    Assert.eq(ProgressDB.get(source.id, "missing").decision_pending, 1)
    Assert.is_nil(ProgressDB.get(source.id, "missing").synced)
    Assert.eq(ProgressDB.get(source.id, "never-read").updated_at, 0, "不能把未读书变成最近阅读")
    Assert.eq(ProgressDB.get(source.id, "never-read").sync_status, 1, "没有阅读记录的零进度不得覆盖新账号")
    Assert.eq(NoteDB.get(source.id, "keep").payload, '[{"text":"保留划线"}]')
    Assert.eq(NoteDB.get(source.id, "never-read").sync_status, 1, "旧账号的空笔记 / 删除意图不上传")
    Assert.len(StatsDB.unsyncedBySource(source.id, 20), 1, "只重推本机采集，不重推导入或云端统计")

    Shelf.reconcile(source.id, {})
    Assert.eq(BookDB.get(source.id, "missing").deleted, 0)
    Shelf.reconcile(source.id, { { source_id = source.id, stable_id = "keep" } }, nil, nil, true)
    Assert.eq(BookDB.get(source.id, "missing").deleted, 0)
    Shelf.reconcile(source.id, { { source_id = source.id, stable_id = "keep", percent = 100 } })
    Assert.eq(BookDB.get(source.id, "missing").deleted, 1)
    Assert.not_nil(BookDB.get(source.id, "missing").path)
    Assert.eq(ProgressDB.get(source.id, "missing").fraction, 0.63)
    Assert.eq(ProgressDB.get(source.id, "keep").fraction, 0.63, "新账号快照不能把保留进度直接改成读完")
    source.putProgressAsync = function() error("不在新书架上，不应上传旧账号进度") end
    require("book.progress").syncAsync(source, {
        identity = { source_id = source.id, stable_id = "missing" }, dirty_only = true,
    })
    Stubs.flush()
    Assert.eq(ProgressDB.get(source.id, "missing").fraction, 0.63)
    Assert.eq(ProgressDB.get(source.id, "missing").decision_pending, 1)
    Assert.eq(ProgressDB.get(source.id, "missing").sync_status, 1, "保留记录但停止反复上传不可访问的书")
end

-- 已经是非成员的有效身份不能被误判下架；卷看父系列。
do
    local source = fixture("account-volumes", false)
    source.volumeParent = function(_self, stable_id)
        if stable_id == "keep:1" then return "keep" end
    end
    Assert.is_true(BookDB.upsertRemote({ source_id = source.id, stable_id = "keep:1", deleted = 1 }))
    Assert.is_true(ProgressDB.upsertRemote(source.id, "keep:1", { fraction = 0.5, updated_at = 10 }))
    Assert.is_true(Logout.clear(source.id, function() end))
    local pushed = 0
    source.putProgressAsync = function(_self, _identity, _pos, cb)
        pushed = pushed + 1
        return Base.defer(cb, true)
    end
    require("book.progress").syncAsync(source, {
        identity = { source_id = source.id, stable_id = "keep:1" }, dirty_only = true,
    })
    Stubs.flush()
    Assert.eq(pushed, 1, "在架系列的非成员卷仍应上传")
    Assert.is_true(ProgressDB.upsert(source.id, "keep:1", { fraction = 0.6, updated_at = 11 }))
    require("book.progress").syncAsync(source, {
        identity = { source_id = source.id, stable_id = "keep:1" }, dirty_only = true,
    })
    Stubs.flush()
    Assert.eq(pushed, 2, "普通非成员进度同步行为不变")
end

-- 整本覆盖的笔记接口不能用旧账号快照覆盖新账号已有划线。
do
    local source = fixture("account-note-merge", true)
    local own = { page = "p1", pos0 = "p1", pos1 = "p2", text = "旧账号划线", datetime = "2026-01-01 01:00:00" }
    local remote = { page = "p3", pos0 = "p3", pos1 = "p4", text = "新账号划线", datetime = "2026-01-01 02:00:00" }
    Assert.is_true(NoteDB.upsert(source.id, "keep", nil, require("json").encode({ own }), 123, true))
    Assert.is_true(Logout.clear(source.id, function() end))
    source.pullNotesAsync = function(_self, _identity, cb) return Base.defer(cb, { remote }) end
    source.pushNotesAsync = function(_self, _identity, annotations, cb)
        Assert.len(annotations, 2, "迁移前先合入新账号已有记录")
        return Base.defer(cb, true)
    end
    require("book.note").syncAsync(source, {
        identity = { source_id = source.id, stable_id = "keep" }, dirty_only = true,
    })
    Stubs.flush()
    Assert.len(require("book.note.normalize").decode(NoteDB.get(source.id, "keep").payload), 2)
end

-- 旧账号的服务端笔记 id 不是新账号的上传确认，正文、备注与定位仍保留。
do
    for _idx, id in ipairs({ "wechat", "kavita" }) do
        local real = require("source." .. id).new()
        local source = fixture("account-note-ids-" .. id, true)
        source.resetAccountAnnotations = real.resetAccountAnnotations
        local item = {
            page = "p1", pos0 = "p1", pos1 = "p2", drawer = "lighten",
            text = "保留正文", note = "保留备注", datetime = "2026-01-01 01:00:00",
            wr_bookmark_id = "old", wr_review_id = "old",
            kavita_id = 99, kavita_note = "保留备注", kavita_xpath = "/p[1]",
        }
        Assert.is_true(NoteDB.upsert(source.id, "keep", nil, require("json").encode({
            item, { wr_deleted = true, wr_bookmark_id = "deleted", kavita_deleted = true, kavita_id = 100 },
        }), 123, true))
        Assert.is_true(Logout.clear(source.id, function() end))
        local annotations = require("book.note.normalize").decode(NoteDB.get(source.id, "keep").payload)
        Assert.len(annotations, 1, "旧账号删除意图不得送到新账号")
        Assert.eq(annotations[1].text, item.text)
        Assert.eq(annotations[1].note, item.note)
        Assert.eq(annotations[1].pos0, item.pos0)
        if id == "wechat" then
            Assert.is_nil(annotations[1].wr_bookmark_id)
            Assert.is_nil(annotations[1].wr_review_id)
            Assert.is_true(require("source.wechat.notes").preparePush(annotations), "保留的笔记必须能上传新账号")
        else
            Assert.is_nil(annotations[1].kavita_id)
            Assert.is_nil(annotations[1].kavita_note)
            Assert.eq(annotations[1].kavita_xpath, item.kavita_xpath, "源坐标不丢")
        end
    end
end

-- 准备失败不取消已发出去的旧账号统计，否则成功回包丢掉会重复计时。
do
    local source = fixture("account-failed-inflight", true)
    Assert.is_true(StatsDB.add({
        source_id = source.id, stable_id = "keep", record_type = "page",
        page = 10, total_pages = 100, start_time = 400, duration = 10,
    }))
    local done
    source.pushStatsAsync = function(_self, _rows, cb)
        done = cb
        return { cancel = function() end }
    end
    require("book.stats").push(source)
    Stubs.flush()
    local original = NoteDB.prepareAccountSync
    NoteDB.prepareAccountSync = function() return false end
    Assert.is_false(Logout.clear(source.id, function() error("准备失败不能改账号") end))
    NoteDB.prepareAccountSync = original
    done({ ok = true })
    Assert.len(StatsDB.unsyncedBySource(source.id, 20), 0, "旧账号仍可确认成功，不重复上报")
end

-- 支持加架的源把旧成员推到新书架，失败的成员保持脏，不被快照下架。
do
    local source = fixture("account-upload", true)
    Assert.is_true(Logout.clear(source.id, function() end))
    local added, removed = {}, {}
    ---@type SyncResult|nil
    local result
    local remote_books = { { stable_id = "keep" } }
    local remote = {
        shelfSyncAsync = function(_self, cb) return Base.defer(cb, remote_books) end,
        addToShelfAsync = function(_self, stable_id, cb)
            added[#added + 1] = stable_id
            if stable_id == "missing" then return Base.defer(cb, nil, "upload failed") end
            remote_books[#remote_books + 1] = { stable_id = stable_id }
            return Base.defer(cb, true)
        end,
        removeFromShelfAsync = function(_self, stable_id, cb)
            removed[#removed + 1] = stable_id
            return Base.defer(cb, true)
        end,
    }
    Shelf.syncAsync(source.id, remote, nil, nil, function(value) result = value end)
    Stubs.flush()
    Assert.len(added, 2)
    Assert.len(removed, 0)
    Assert.eq(result.pushed, 1)
    Assert.eq(BookDB.get(source.id, "missing").deleted, 0)
    Assert.eq(BookDB.get(source.id, "missing").sync_status, 0)
    Assert.eq(BookDB.get(source.id, "never-read").sync_status, 1)
end

-- 不在后台队列里的旧同步也可能迟到：不能撕保留墓碑或确认新账号的记录。
do
    local source = fixture("account-inflight", true)
    Assert.is_true(ProgressDB.upsert(source.id, "keep", { fraction = 0.63, updated_at = 123 }))
    Assert.is_true(NoteDB.upsert(source.id, "keep", nil, '[{"text":"保留划线"}]', 123))
    Assert.is_true(StatsDB.add({
        source_id = source.id, stable_id = "keep", record_type = "page",
        page = 10, total_pages = 100, start_time = 400, duration = 10,
    }))
    local delete_done, progress_done, note_done, stats_done
    Shelf.pushDeletes(source.id, function(_id, cb)
        delete_done = cb
        return { cancel = function() end }
    end, function() end, function() end)
    source.putProgressAsync = function(_self, _identity, _pos, cb)
        progress_done = cb
        return { cancel = function() end }
    end
    source.pushNotesAsync = function(_self, _identity, _notes, cb)
        note_done = cb
        return { cancel = function() end }
    end
    source.pushStatsAsync = function(_self, _rows, cb)
        stats_done = cb
        return { cancel = function() end }
    end
    require("book.progress").syncAsync(source, { identity = { source_id = source.id, stable_id = "keep" }, dirty_only = true })
    require("book.note").syncAsync(source, { identity = { source_id = source.id, stable_id = "keep" }, dirty_only = true })
    require("book.stats").push(source)
    Stubs.flush()
    Assert.is_true(Logout.replaceLibrary(source.id, function() end))
    delete_done(true)
    progress_done(true)
    note_done(true)
    stats_done({ ok = true })
    Assert.not_nil(BookDB.get(source.id, "tombstone"))
    Assert.eq(ProgressDB.get(source.id, "tombstone").fraction, 0.63)
    Assert.eq(ProgressDB.get(source.id, "keep").sync_status, 0)
    Assert.eq(NoteDB.get(source.id, "keep").sync_status, 0)
    Assert.len(StatsDB.unsyncedBySource(source.id, 20), 2)
end

-- 准备失败整批回滚，不改配置、时间、旧同步状态或账号版本。
do
    local source = fixture("account-rollback", true)
    local original = NoteDB.prepareAccountSync
    NoteDB.prepareAccountSync = function() return false end
    local current, committed = Auth.currentAccount(source.id), false
    Assert.is_false(Logout.replaceLibrary(source.id, function() committed = true end))
    NoteDB.prepareAccountSync = original
    Assert.is_false(committed)
    Assert.is_true(current())
    Assert.eq(BookDB.get(source.id, "keep").sync_status, 1)
    Assert.eq(BookDB.get(source.id, "tombstone").sync_status, 0)
    Assert.eq(ProgressDB.get(source.id, "keep").sync_status, 1)
    Assert.not_nil(ProgressDB.get(source.id, "keep").synced)
end

-- WebDAV 只迁移远端身份，不能把纯本地书和导入历史重新推送。
do
    Assert.is_true(BookDB.upsertRemote({ source_id = "local", stable_id = "webdav://book.epub", deleted = 0 }))
    Assert.is_true(BookDB.upsertRemote({ source_id = "local", stable_id = "/books/native.epub", deleted = 0 }))
    Assert.is_true(ProgressDB.upsertRemote("local", "webdav://book.epub", { fraction = 0.5, updated_at = 42 }))
    Assert.is_true(ProgressDB.upsertRemote("local", "/books/native.epub", { fraction = 0.7, updated_at = 43 }))
    Assert.is_true(BookDB.prepareAccountSync("local", true, "webdav://"))
    Assert.eq(BookDB.get("local", "webdav://book.epub").sync_status, 0)
    Assert.eq(BookDB.get("local", "/books/native.epub").sync_status, 1)
    Assert.eq(ProgressDB.get("local", "webdav://book.epub").sync_status, 0)
    Assert.eq(ProgressDB.get("local", "/books/native.epub").sync_status, 1)
end

DB.close()
return true
