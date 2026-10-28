--[[--
source.moon 门面离线用例：书架同步 / 本地查询 / onEvent 事件分发 / progress 映射。

书架同步经远端 listQuery 拉全量；书架展示与筛选则必须经过 book.catalog。
onEvent 的 KOReader UI 依赖按约定函数内延迟加载，这里用 preload 打桩。

@module tests.source.moon_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")

-- 假客户端：记录入参、回放预设响应
local rec = {}
local client = {}
local lfs = require("libs/libkoreader-lfs")
local open_dir = os.tmpname() .. ".moon-open"
os.remove(open_dir)
assert(lfs.mkdir(open_dir))

package.preload["utils.settings"] = function()
    return {
        getSource = function() return {} end,
    }
end

package.preload["source.moon.client"] = function()
    return {
        new = function() return client end,
    }
end

package.preload["utils.paths"] = function()
    return {
        ensureBookWork = function() end,
        bookWorkDir = function() return open_dir end,
        coverPath = function() return open_dir .. "/cover.jpg" end,
    }
end

package.preload["book.books_db"] = function()
    return {
        reconcile = function(source_id, books)
            rec.reconciled_source = source_id
            rec.reconciled_books = books
            return true, 0
        end,
        libraryStableIdsBySource = function() return { "a.epub", "b.epub" } end,
        pendingDeleteIds = function()
            return rec.marked_deleted and not rec.removed and { rec.marked_deleted.stable_id } or {}
        end,
        unsynced = function()
            return rec.marked_deleted and not rec.removed and { rec.marked_deleted } or {}
        end,
        markSynced = function() return true end,
        get = function() return rec.stored_book end,
        setRead = function(source_id, stable_id, is_read)
            rec.set_read = { source_id = source_id, stable_id = stable_id, is_read = is_read }
            return true
        end,
        remove = function(source_id, stable_id)
            rec.removed = { source_id = source_id, stable_id = stable_id }
            return true
        end,
    }
end
package.preload["book.chapters_db"] = function()
    return {
        deleteUnder = function(dir)
            rec.chapter_deleted_under = dir
            return true
        end,
    }
end
package.preload["ffi/util"] = function()
    return {
        purgeDir = function() return true end,
        template = function(s) return s end,
    }
end
package.preload["book.progress_db"] = function()
    return {
        upsertRemote = function(source_id, stable_id, pos)
            rec.remote_progress = rec.remote_progress or {}
            rec.remote_progress[#rec.remote_progress + 1] = {
                source_id = source_id, stable_id = stable_id, pos = pos,
            }
            return true
        end,
        unsynced = function() return {} end,
    }
end
-- 推脏只查脏行存在性：笔记 / 统计这两张表这里没有脏行
package.preload["book.note_db"] = function()
    return { hasUnsynced = function() return false end }
end
package.preload["book.stats_db"] = function()
    return { unsyncedBySource = function() return {} end }
end

package.preload["book.catalog"] = function()
    return {
        listResult = function(books, count)
            local data = books or {}
            return { data = data, count = tonumber(count) or #data }
        end,
    }
end

package.preload["ui/network/manager"] = function()
    return {
        runWhenConnected = function(_, fn) fn() end,
        isConnected = function() return not rec.offline end,
    }
end

local Themed = require("support.theme_stubs")
Themed.install()
package.preload["workers.ui.task_dialog"] = function()
    return { follow = function() end }
end

local touches = {}
package.preload["book.store"] = function()
    return {
        touch = function(path, identity)
            touches[#touches + 1] = { path = path, identity = identity }
            return true
        end,
        rememberMany = function(books)
            rec.remembered_books = books
        end,
        markDeleted = function(source_id, stable_id)
            rec.marked_deleted = { source_id = source_id, stable_id = stable_id }
            return true
        end,
    }
end

-- onEvent 延迟加载的 UI 依赖：记录调用
local sync = { push_calls = 0, last_source = nil, push_args = nil }

-- 全量拉书架前会清列表缓存；单测不碰真 sqlite，只记清了什么。
local cache_cleared = {}
package.preload["http.cache"] = function()
    return { clear = function(substr) cache_cleared[#cache_cleared + 1] = substr end }
end
package.loaded["http.cache"] = nil

package.preload["book.stats"] = function()
    return {
        syncAsync = function(self, _, cb)
            sync.push_calls = sync.push_calls + 1
            sync.pull_calls = (sync.pull_calls or 0) + 1
            sync.last_source = self
            cb({ pulled = 1, pushed = 1 })
            return { cancel = function() end }
        end,
        push = function(self, cb)
            sync.push_calls = sync.push_calls + 1
            sync.last_source = self
            if cb then cb(true, { ok = true }) end
        end,
        pull = function(self, cb)
            sync.pull_calls = (sync.pull_calls or 0) + 1
            sync.last_source = self
            if cb then cb(true, { imported = 0 }) end
        end,
    }
end

-- 假 client 方法（moon.lua 一律冒号调用，首参是 client 自身）
function client:configured()
    return true
end

function client:listBooksAsync(query, cb)
    rec.query = query
    cb(rec.list_wire, rec.list_err)
    return { cancel = function() end }
end

function client:filtersAsync(cb)
    cb(rec.filters_wire, rec.filters_err)
    return { cancel = function() end }
end

function client:getProgressAsync(stable_id, cb)
    rec.progress_id = stable_id
    cb(rec.progress_wire, rec.progress_err)
    return { cancel = function() end }
end

function client:updateProgressAsync(payload, cb)
    rec.put_payload = payload
    if rec.put_err then
        cb(nil, rec.put_err)
    else
        cb({ ok = true })
    end
    return { cancel = function() end }
end

function client:deleteBooksAsync(filenames, cb)
    rec.delete_books = filenames
    if rec.delete_err then
        cb(nil, rec.delete_err)
    else
        cb({ ok = true })
    end
    return { cancel = function() end }
end

function client:syncAnnotationsAsync(payload, cb)
    rec.annotations_payload = payload
    cb({ ok = true })
    return { cancel = function() end }
end

function client:getAnnotationsAsync(stable_id, cb)
    rec.annotations_id = stable_id
    cb({ data = { annotations = { { page = "/p", datetime = "2026-08-20" } } } })
    return { cancel = function() end }
end

function client:syncStatsAsync(payload, cb)
    rec.stats_payload = payload
    cb({ ok = true })
    return { cancel = function() end }
end

function client:getStatsAsync(cb)
    rec.stats_fetches = (rec.stats_fetches or 0) + 1
    cb({ data = { stats = {
        { book_filename = "a.epub", page = 1, start_time = 1001, duration = 30, total_pages = 100 },
        { book_filename = "b.epub", page = 2, start_time = 1002, duration = 30, total_pages = 100 },
    } } })
    return { cancel = function() end }
end

function client:downloadBookAsync(stable_id, path, on_progress, cb)
    rec.download_count = (rec.download_count or 0) + 1
    rec.download_id = stable_id
    rec.download_path = path
    if rec.defer_download then
        rec.download_done = cb
        rec.download_progress = on_progress
        return { cancel = function() end }
    end
    local file = assert(io.open(path, "wb"))
    file:write(rec.download_body or "PK\003\004book")
    file:close()
    if on_progress then on_progress(8, rec.download_total) end
    cb(rec.download_ok ~= false, rec.download_err)
    return { cancel = function() end }
end

local Moon = require("source.moon")
local src = Moon.new()

local function resetRec()
    for k in pairs(rec) do rec[k] = nil end
end

-- syncBooksAsync：完整书架拉取后写入本地库
do
    resetRec()
    rec.list_wire = { data = { { filename = "a.epub", title = "A" } }, count = 1 }
    local result
    src:syncBooksAsync(nil, function(value) result = value end)
    require("support.stubs").flush()
    Assert.eq(rec.query.page, 1)
    Assert.eq(rec.query.pageSize, 200)
    Assert.eq(cache_cleared[#cache_cleared], "/index/book/list", "全量同步前清列表缓存")
    Assert.eq(rec.query.search, "")
    Assert.eq(rec.query.series, "")
    Assert.eq(rec.query.category, "")
    Assert.is_nil(rec.query.favorite)
    Assert.is_nil(rec.query.finished)
    Assert.is_nil(rec.query.author)
    Assert.eq(rec.reconciled_source, "moon")
    Assert.eq(rec.reconciled_books[1].stable_id, "a.epub")
    Assert.eq(result.pulled, 1)
end

-- openBookAsync：Moon 自己完成缓存、下载、校验、并发合并和落库。
do
    local path = open_dir .. "/book.epub"
    os.remove(path)
    os.remove(path .. ".part")
    resetRec()
    touches = {}
    local made = #Themed.made
    rec.download_total = 8

    local opened, open_err
    src:openBookAsync({
        source_id = "moon",
        stable_id = "library/a.epub",
        book = { title = "A" },
    }, nil, function(p, err) opened, open_err = p, err end)
    require("support.stubs").flush()
    Assert.eq(rec.download_count, 1)
    Assert.eq(rec.download_id, "library/a.epub")
    Assert.eq(rec.download_path, path, "Request.download 自己写 .part，不再套一层")
    -- 一个不可关的进度框：标题是书名，按字节推进，结束关掉。
    Assert.eq(#Themed.made, made + 1)
    local dialog = Themed.last("progress_dialog")
    Assert.eq(dialog.title, "A")
    Assert.is_true(dialog.dismissable == false)
    Assert.is_true(dialog.shown and dialog.closed)
    Assert.eq(dialog.progress[1], 8)
    Assert.eq(dialog.progress[2], 8)
    Assert.eq(opened, path)
    Assert.is_nil(open_err)
    Assert.eq(touches[1].path, path)

    -- 服务端不给 Content-Length：进度条不动。
    os.remove(path)
    resetRec()
    made = #Themed.made
    opened = nil
    src:openBookAsync({ source_id = "moon", stable_id = "library/a.epub" }, nil, function(p) opened = p end)
    require("support.stubs").flush()
    Assert.eq(#Themed.made, made + 1)
    dialog = Themed.last("progress_dialog")
    Assert.is_true(dialog.shown and dialog.closed)
    Assert.is_nil(dialog.progress)
    Assert.eq(opened, path)

    local registered_path = open_dir .. "/legacy.epub"
    local registered = assert(io.open(registered_path, "wb"))
    registered:write("PK\003\004book")
    registered:close()
    resetRec()
    rec.stored_book = { path = registered_path }
    opened = nil
    src:openBookAsync({
        source_id = "moon",
        stable_id = "library/a.epub",
        book = { title = "旧缓存" },
    }, nil, function(p) opened = p end)
    Assert.is_nil(opened, "缓存命中也在下一拍回调，调用方先拿到句柄")
    require("support.stubs").flush()
    Assert.is_nil(rec.download_count)
    Assert.eq(opened, registered_path)
    os.remove(registered_path)

    resetRec()
    opened = nil
    local job = src:openBookAsync({ source_id = "moon", stable_id = "library/a.epub" }, nil, function(p)
        opened = p
    end)
    job.cancel()
    require("support.stubs").flush()
    Assert.is_nil(opened, "取消后不回调")
    src:openBookAsync({ source_id = "moon", stable_id = "library/a.epub" }, nil, function(p)
        opened = p
    end)
    require("support.stubs").flush()
    Assert.is_nil(rec.download_count)
    Assert.eq(opened, path)

    os.remove(path)
    resetRec()
    rec.defer_download = true
    local first, second
    src:openBookAsync({ source_id = "moon", stable_id = "library/a.epub" }, nil, function(p) first = p end)
    src:openBookAsync({ source_id = "moon", stable_id = "library/a.epub" }, nil, function(p) second = p end)
    require("support.stubs").flush()
    Assert.eq(rec.download_count, 1)
    local file = assert(io.open(path, "wb"))
    file:write("PK\003\004book")
    file:close()
    rec.download_done(true)
    Assert.eq(first, path)
    Assert.eq(second, path)

    os.remove(path)
    resetRec()
    opened = nil
    rec.download_body = "XXXX"
    src:openBookAsync({ source_id = "moon", stable_id = "library/a.epub" }, nil, function(p, err)
        opened, open_err = p, err
    end)
    require("support.stubs").flush()
    Assert.is_nil(opened)
    Assert.eq(open_err, "下载文件校验失败")
    Assert.is_nil(lfs.attributes(path), "校验失败的文件要删掉")
end

-- onEvent：阅读生命周期由 session 处理；这里只响应用户统计同步请求
do
    sync.push_calls = 0
    sync.pull_calls = 0

    src:onEvent("document_close")
    Assert.eq(sync.push_calls, 0)

    src:onEvent("suspend")
    Assert.eq(sync.push_calls, 0)

    src:onEvent("page_changed")
    Assert.eq(sync.push_calls, 0)
end

-- getProgressAsync：/book/progress 的 data → ProgressPosition（percent/100、spine、locator 空串归 nil）
do
    resetRec()
    rec.progress_wire = {
        code = 200, data = { percent = 30, spine = 5, page = 9, offset = 0, locator = "", timestamp = 0 },
    }
    local pos, err
    src:getProgressAsync({ stable_id = "a.epub" }, function(p, e) pos, err = p, e end)
    Assert.is_nil(err)
    Assert.eq(rec.progress_id, "a.epub")
    Assert.eq(pos.fraction, 0.3)
    Assert.eq(pos.chapter_idx, 5)
    Assert.eq(pos.page, 9)
    Assert.is_nil(pos.locator, "空串应归一成 nil")
end

-- 云端没有进度（data 为 null）：meta.empty，不报错
do
    resetRec()
    rec.progress_wire = { code = 200 }
    local pos, err, meta
    src:getProgressAsync({ stable_id = "a.epub" }, function(p, e, m) pos, err, meta = p, e, m end)
    Assert.is_nil(pos)
    Assert.is_nil(err)
    Assert.is_true(meta.empty)
end

-- 拉取失败透传错误
do
    resetRec()
    rec.progress_err = "无进度"
    local pos, err
    src:getProgressAsync({ stable_id = "a.epub" }, function(p, e) pos, err = p, e end)
    Assert.is_nil(pos)
    Assert.eq(err, "无进度")
end

-- putProgressAsync：fraction 钳制、spine/percent 组装
do
    resetRec()
    local ok, err
    src:putProgressAsync({ stable_id = "a.epub" }, { fraction = 0.5, chapter_idx = 2 }, function(o, e)
        ok, err = o, e
    end)
    Assert.is_true(ok)
    Assert.is_nil(err)
    Assert.eq(rec.put_payload.filename, "a.epub")
    Assert.eq(rec.put_payload.frac, 0.5)
    Assert.eq(rec.put_payload.spine, 2)
    Assert.eq(rec.put_payload.page, 0)
    Assert.eq(rec.put_payload.percent, "50.00%")

    -- 精确坐标必须发出去：不发的话服务端永远存不到，拉回来只有会漂移的百分比
    src:putProgressAsync({ stable_id = "a.epub" }, {
        fraction = 0.5, chapter_idx = 2, page = 12, locator = "/body/p[7]",
        extra = { offset = 8 },
    }, function() end)
    Assert.eq(rec.put_payload.locator, "/body/p[7]")
    Assert.eq(rec.put_payload.page, 12)
    Assert.eq(rec.put_payload.offset, 8)

    -- fraction 超 1 按百分数钳制（42 → 0.42）；chapter_idx 缺省 spine = 0
    src:putProgressAsync({ stable_id = "b.epub" }, { fraction = 42 }, function() end)
    Assert.eq(rec.put_payload.frac, 0.42)
    Assert.eq(rec.put_payload.spine, 0)
    Assert.eq(rec.put_payload.percent, "42.00%")

    -- pos 缺省：fraction 0
    src:putProgressAsync({ stable_id = "b.epub" }, nil, function() end)
    Assert.eq(rec.put_payload.frac, 0)
    Assert.eq(rec.put_payload.percent, "0.00%")

    -- 失败透传
    rec.put_err = "网络故障"
    src:putProgressAsync({ stable_id = "b.epub" }, { fraction = 0.1 }, function(o, e)
        ok, err = o, e
    end)
    Assert.is_nil(ok)
    Assert.eq(err, "网络故障")
end

-- 注解同步：领域层只传 identity + annotations，Moon 源才映射后端 filename。
do
    resetRec()
    local ok
    src:pushNotesAsync({ source_id = "moon", stable_id = "a.epub", chapter_idx = 2 }, {
        { datetime = "2026-08-20", page = "/p" },
    }, function(res)
        ok = res
    end)
    Assert.not_nil(ok)
    Assert.eq(rec.annotations_payload.filename, "a.epub")
    Assert.eq(rec.annotations_payload.device_id, "koreader")
    Assert.eq(rec.annotations_payload.annotations[1].page, "/p")
end

do
    resetRec()
    local annotations, meta
    src:pullNotesAsync({ stable_id = "a.epub" }, function(rows, _, info)
        annotations, meta = rows, info
    end)
    Assert.eq(rec.annotations_id, "a.epub")
    Assert.len(annotations, 1)
    Assert.is_true(meta.authoritative)
end

-- 统计同步：book.stats 只传领域记录，Moon 源负责 wire 字段。
do
    resetRec()
    local response
    src:pushStatsAsync({
        { stable_id = "a.epub", page = 3, start_time = 1000, duration = 30, total_pages = 100 },
    }, function(res) response = res end)
    Assert.not_nil(response)
    Assert.eq(rec.stats_payload.books[1].filename, "a.epub")
    Assert.eq(rec.stats_payload.stats[1].filename, "a.epub")
    Assert.is_nil(rec.stats_payload.stats[1].stable_id)
    Assert.eq(rec.stats_payload.device_id, "koreader")
end

-- 统计拉取：Moon 源一次获取账户完整快照。
do
    resetRec()
    local rows
    src:pullStatsAsync(function(value) rows = value end)
    Assert.eq(rec.stats_fetches, 1)
    Assert.eq(rows.replace.mode, "all_synced")
    Assert.len(rows.rows, 2)
    Assert.eq(rows.rows[1].source_id, "moon")
    Assert.eq(rows.rows[1].stable_id, "a.epub")
    Assert.eq(rows.rows[2].stable_id, "b.epub")
    Assert.eq(rows.rows[2].duration, 30)
end

-- 长按删除：本地先标删，已连网时顺手入队推脏（同源只留一条）；推脏的书架域推云端真删并撕墓碑
do
    resetRec()
    local enqueued = {}
    package.loaded["workers.tasks"] = { enqueue = function(spec) enqueued[#enqueued + 1] = spec.key; return spec end }
    src.configured = function() return true end
    local ok, err
    src:deleteBookAsync({ source_id = "moon", stable_id = "a.epub" }, function(success, e)
        ok, err = success, e
    end)
    require("support.stubs").flush()
    Assert.is_true(ok)
    Assert.is_nil(err)
    Assert.eq(rec.marked_deleted.stable_id, "a.epub")
    Assert.eq(enqueued[1], "dirty\0moon")
    src:syncBooksAsync({ dirty_only = true }, function() end)
    require("support.stubs").flush()
    Assert.eq(rec.delete_books[1], "a.epub")
    Assert.eq(rec.removed.stable_id, "a.epub")

    -- 服务端答「不存在」：删除目的已达成，照样撕墓碑；其它错误保留墓碑下轮重试
    rec.removed, rec.delete_err = nil, "书籍不存在"
    src:syncBooksAsync({ dirty_only = true }, function() end)
    require("support.stubs").flush()
    Assert.eq(rec.removed.stable_id, "a.epub")
    rec.removed, rec.delete_err = nil, "请求失败 (HTTP 500)"
    src:syncBooksAsync({ dirty_only = true }, function() end)
    require("support.stubs").flush()
    Assert.is_nil(rec.removed)

    -- 离线删除：只落本地墓碑并立即回调成功，不入队、不发请求、不撕墓碑
    resetRec()
    enqueued = {}
    rec.offline = true
    src:deleteBookAsync({ source_id = "moon", stable_id = "a.epub" }, function(success) ok = success end)
    require("support.stubs").flush()
    Assert.is_true(ok)
    Assert.eq(rec.marked_deleted.stable_id, "a.epub")
    Assert.len(enqueued, 0)
    Assert.is_nil(rec.delete_books)
    Assert.is_nil(rec.removed)
    package.loaded["workers.tasks"] = nil
    src.configured = nil
end

-- 还原 preload/loaded，避免影响本文件之后的用例
for _, name in ipairs({
    "utils.settings",
    "utils.paths",
    "book.books_db",
    "book.chapters_db",
    "book.progress_db",
    "book.note_db",
    "book.stats_db",
    "ffi/util",
    "source.moon.client",
    "ui/network/manager",
    "workers.ui.task_dialog",
    "book.store",
    "book.stats",
    "source.moon",
}) do
    package.preload[name] = nil
    package.loaded[name] = nil
end
os.remove(open_dir .. "/book.epub")
os.remove(open_dir .. "/book.epub.part")
lfs.rmdir(open_dir)
