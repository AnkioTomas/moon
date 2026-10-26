--[[--
书架双向同步：本地删/加上行 + 远端快照 reconcile。

- `pushDeletes`：所有有远端删除接口的源共用（moon / copymanga / wechat / jdread），源只给「删一本」。
- `syncAsync`：有 add/remove 书架 API 的源（微信读书、京东读书）共用；远端由调用方显式传入 ``remote``，
  需提供冒号方法 ``shelfSyncAsync(cb)`` / ``addToShelfAsync(stable_id, cb)`` / ``removeFromShelfAsync(stable_id, cb)``。
- `reconcile`：远端快照对账，返回 SyncResult。

回调一律异步（无事可做时也下一帧回调），见 `SourceBase.defer`。

@module koplugin.book.source.shelf
--]]

local SourceBase = require("source.base")
local logger = require("utils.log")
local _ = require("gettext")
local T = require("ffi/util").template

local Shelf = {}

---@alias ShelfReport fun(text: string, done: integer|nil, total: integer|nil)

--- 用远端书架快照对账 books 表；pushed 由源在 add/delete 上行后自行累加。
---@param source_id string
---@param books Book[]
---@param force boolean|nil 用户强制刷新：快照里的 meta 覆盖本地已有键
---@param inserted_at_from_row boolean|nil 快照行自带权威加入时间（如 Kavita 的 lastChapterAddedUtc）
---@return SyncResult|nil result
---@return string|nil err
function Shelf.reconcile(source_id, books, force, inserted_at_from_row)
    local ok, hidden = require("book.books_db").reconcile(source_id, books, {
        force = force,
        allow_empty = force,
        inserted_at_from_row = inserted_at_from_row,
    })
    if not ok then return nil, "failed to reconcile books" end
    -- 远端书架快照自带的进度（percent 0..100）：读完必标已读，读到 99% 看设置，与本机阅读会话同一规则。
    local BookDB = require("book.books_db")
    for _idx, book in ipairs(books) do
        local percent = tonumber(book.percent) or 0
        if percent >= 100
            or percent >= 99 and require("utils.settings").get("reader").auto_mark_read_at_99 == true then
            BookDB.markReadAutomatically(source_id, book.stable_id)
        end
    end
    return { pulled = #books, pushed = 0, hidden = hidden, conflicts = 0, skipped = false }
end

---@param job { cancel: fun() }|nil
local function cancel(job)
    if job then job:cancel() end
end

--- 逐本串行调用 push_one；done 传真值才计入 pushed，失败继续下一本。
---@param ids string[]
---@param push_one fun(stable_id: string, done: fun(ok: any)): { cancel: fun() }|nil
---@param label string 进度文案
---@param report ShelfReport
---@param cb fun(pushed: integer)
---@return { cancel: fun() }
local function pushEach(ids, push_one, label, report, cb)
    if #ids == 0 then return SourceBase.defer(cb, 0) end
    local cancelled, job, pushed, index = false, nil, 0, 0
    local function nextId()
        if cancelled then return end
        index = index + 1
        if index > #ids then
            cb(pushed)
            return
        end
        report(label, index, #ids)
        job = push_one(ids[index], function(ok)
            if cancelled then return end
            if ok then pushed = pushed + 1 end
            nextId()
        end)
    end
    nextId()
    return { cancel = function()
        cancelled = true
        cancel(job)
    end }
end

--- 本地已标删的书：逐本 remove_one 推远端，成功则撕墓碑。
---@type table<string, boolean> 源 id → 正在推删（启动 pushDirty 与书架同步并发时同一本只推一次）
local deleting = {}

---@param source_id string
---@param remove_one fun(stable_id: string, done: fun(ok: any)): { cancel: fun() }|nil 远端删一本
---@param report ShelfReport
---@param cb fun(pushed: integer)
---@return { cancel: fun() }
function Shelf.pushDeletes(source_id, remove_one, report, cb)
    local BookDB = require("book.books_db")
    -- 已有一轮在推：本轮跳过。没推完的墓碑是脏行，reconcile 不会把它复活。
    if deleting[source_id] then return SourceBase.defer(cb, 0) end
    deleting[source_id] = true
    local job = pushEach(BookDB.pendingDeleteIds(source_id), function(stable_id, done)
        return remove_one(stable_id, function(ok)
            done(ok and BookDB.remove(source_id, stable_id))
        end)
    end, _("正在同步删除的书"), report, function(pushed)
        deleting[source_id] = nil
        cb(pushed)
    end)
    return { cancel = function()
        deleting[source_id] = nil
        job:cancel()
    end }
end

--- 本地新加架（脏行）上行。remote_ids 里已有的直接标已同步，不再发请求。
---@param source_id string
---@param remote table 书架远端（见模块头注释）
---@param remote_ids table<string, boolean>
---@param report ShelfReport
---@param cb fun(pushed: integer)
---@return { cancel: fun() }
local function pushAdded(source_id, remote, remote_ids, report, cb)
    local BookDB = require("book.books_db")
    local missing = {}
    for _idx, stable_id in ipairs(BookDB.pendingShelfAddIds(source_id)) do
        if remote_ids[stable_id] then
            BookDB.markSynced(source_id, stable_id)
        else
            missing[#missing + 1] = stable_id
        end
    end
    return pushEach(missing, function(stable_id, done)
        return remote:addToShelfAsync(stable_id, function(wire, err)
            if not wire then
                logger.warn(source_id .. " shelf push failed", stable_id, err)
                done(false)
                return
            end
            local ok = BookDB.markSynced(source_id, stable_id)
            if not ok then logger.warn(source_id .. " shelf mark synced failed", stable_id) end
            done(ok)
        end)
    end, _("正在同步加入书架的书"), report, cb)
end

--- 书架同步。dirty_only：只推本地删/加，不拉书架、不对账；
--- 全量：先推删 → 拉远端 → 推本地新加 →（有推送则再拉）→ reconcile。
---@param source_id string
---@param remote table 书架远端（见模块头注释）
---@param to_books fun(wire: table): Book[] 书架 wire 映射（封面等副产物由源在这里自己记）
---@param opts { dirty_only?: boolean, force?: boolean, on_progress?: ShelfReport }|nil
---@param cb fun(result: SyncResult|nil, err: any)
---@return { cancel: fun() }
function Shelf.syncAsync(source_id, remote, to_books, opts, cb)
    opts = opts or {}
    local report = opts.on_progress or function(...) end
    local cancelled, job, push_job, delete_job = false, nil, nil, nil
    local handle = { cancel = function()
        cancelled = true
        cancel(job)
        cancel(push_job)
        cancel(delete_job)
    end }

    local function removeOne(stable_id, done)
        return remote:removeFromShelfAsync(stable_id, function(wire, err)
            if not wire then logger.warn(source_id .. " shelf delete push failed", stable_id, err) end
            done(wire)
        end)
    end

    if opts.dirty_only then
        delete_job = Shelf.pushDeletes(source_id, removeOne, report, function(deleted_n)
            if cancelled then return end
            push_job = pushAdded(source_id, remote, {}, report, function(pushed)
                if cancelled then return end
                cb({ pulled = 0, pushed = deleted_n + pushed, hidden = 0, conflicts = 0, skipped = false })
            end)
        end)
        return handle
    end

    ---@param next_step fun(books: Book[])
    local function pull(next_step)
        report(_("正在拉取书架…"))
        job = remote:shelfSyncAsync(function(wire, err)
            if cancelled then return end
            if not wire then cb(nil, err); return end
            next_step(to_books(wire))
        end)
    end
    ---@param books Book[]
    ---@param pushed integer
    local function reconcile(books, pushed)
        report(T(_("正在写入书架（%1 本）"), #books))
        local result, err = Shelf.reconcile(source_id, books, opts.force)
        if not result then cb(nil, err); return end
        result.pushed = pushed
        cb(result)
    end

    delete_job = Shelf.pushDeletes(source_id, removeOne, report, function(deleted_n)
        if cancelled then return end
        pull(function(books)
            local remote_ids = {}
            for _idx, book in ipairs(books) do remote_ids[book.stable_id] = true end
            push_job = pushAdded(source_id, remote, remote_ids, report, function(pushed)
                if cancelled then return end
                if pushed == 0 then
                    reconcile(books, deleted_n)
                    return
                end
                pull(function(fresh) reconcile(fresh, deleted_n + pushed) end)
            end)
        end)
    end)
    return handle
end

return Shelf
