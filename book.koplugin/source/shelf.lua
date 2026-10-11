--[[--
书架双向同步：本地删/加上行 + 远端快照 reconcile。

供有 add/remove 书架 API 的源（微信读书、京东读书）共用；源实例只需 ``id``，
远端由调用方显式传入 ``remote``，需提供冒号方法
``shelfSyncAsync(cb)`` / ``addToShelfAsync(stable_id, cb)`` / ``removeFromShelfAsync(stable_id, cb)``。

@module koplugin.book.source.shelf
--]]

local logger = require("utils.log")
local _ = require("gettext")
local T = require("ffi/util").template

local Shelf = {}

---@alias ShelfReport fun(text: string, done: integer|nil, total: integer|nil)

--- 用远端书架快照对账 books 表；pushed 由源在 add/delete 上行后自行累加。
---@param source_id string
---@param books Book[]
---@return SyncResult|nil result
---@return string|nil err
function Shelf.reconcile(source_id, books)
    local ok, hidden = require("book.books_db").reconcile(source_id, books)
    if not ok then return nil, "failed to reconcile books" end
    return { pulled = #books, pushed = 0, hidden = hidden, conflicts = 0, skipped = false }
end

---@param job { cancel: fun() }|nil
local function cancel(job)
    if job and job.cancel then job:cancel() end
end

--- 逐本调用 ``remote[method]`` 串行上行；on_ok 返回真才计入 pushed，失败只记日志继续下一本。
---@param source SourceBase
---@param remote table 书架远端（见模块头注释）
---@param ids string[]
---@param method string client 方法名
---@param on_ok fun(stable_id: string): boolean
---@param fail_log string 失败日志后缀
---@param label string 进度文案
---@param report ShelfReport
---@param cb fun(pushed: integer)
---@return { cancel: fun() }|nil
local function pushEach(source, remote, ids, method, on_ok, fail_log, label, report, cb)
    if #ids == 0 then
        cb(0)
        return nil
    end
    local cancelled, job, pushed, index = false, nil, 0, 0
    local function nextId()
        if cancelled then return end
        index = index + 1
        if index > #ids then
            cb(pushed)
            return
        end
        report(label, index, #ids)
        local stable_id = ids[index]
        job = remote[method](remote, stable_id, function(wire, err)
            if cancelled then return end
            if wire then
                if on_ok(stable_id) then
                    pushed = pushed + 1
                end
            elseif err then
                logger.warn(source.id .. fail_log, stable_id, err)
            end
            nextId()
        end)
    end
    nextId()
    return { cancel = function()
        cancelled = true
        cancel(job)
    end }
end

--- 本地已标删的书：推云端 remove，成功则撕墓碑。
---@param source SourceBase
---@param remote table 书架远端（见模块头注释）
---@param report ShelfReport
---@param cb fun(pushed: integer)
---@return { cancel: fun() }|nil
local function pushDeleted(source, remote, report, cb)
    local BookDB = require("book.books_db")
    return pushEach(source, remote, BookDB.pendingDeleteIds(source.id), "removeFromShelfAsync",
        function(stable_id)
            return BookDB.remove(source.id, stable_id)
        end, " shelf delete push failed", _("正在同步删除的书"), report, cb)
end

--- 本地新加架（脏行）上行。remote_ids 里已有的直接标已同步，不再发请求。
---@param source SourceBase
---@param remote table 书架远端（见模块头注释）
---@param remote_ids table<string, boolean>|nil
---@param report ShelfReport
---@param cb fun(pushed: integer)
---@return { cancel: fun() }|nil
local function pushAdded(source, remote, remote_ids, report, cb)
    local BookDB = require("book.books_db")
    local missing = {}
    for _idx, stable_id in ipairs(BookDB.pendingShelfAddIds(source.id)) do
        if remote_ids and remote_ids[stable_id] then
            BookDB.markSynced(source.id, stable_id)
        else
            missing[#missing + 1] = stable_id
        end
    end
    return pushEach(source, remote, missing, "addToShelfAsync", function(stable_id)
        if BookDB.markSynced(source.id, stable_id) then
            return true
        end
        logger.warn(source.id .. " shelf mark synced failed", stable_id)
        return false
    end, " shelf push failed", _("正在同步加入书架的书"), report, cb)
end

--- 书架同步。dirty_only：只推本地删/加，不拉书架、不对账；
--- 全量：先推删 → 拉远端 → 推本地新加 →（有推送则再拉）→ reconcile。
---@param source SourceBase
---@param remote table 书架远端（见模块头注释）
---@param opts { dirty_only?: boolean, on_progress?: ShelfReport }|nil
---@param cb fun(result: SyncResult|nil, err: any)
---@param on_cover fun(stable_id: string, url: string) 书架列表里的封面 URL
---@param shelf_list fun(wire: table, on_cover: function): BookListResult 书架 wire 映射
---@return { cancel: fun() }
function Shelf.syncAsync(source, remote, opts, cb, on_cover, shelf_list)
    local report = opts and opts.on_progress or function(...) end
    local cancelled, job, push_job, delete_job = false, nil, nil, nil
    local handle = { cancel = function()
        cancelled = true
        cancel(job)
        cancel(push_job)
        cancel(delete_job)
    end }

    if opts and opts.dirty_only then
        delete_job = pushDeleted(source, remote, report, function(deleted_n)
            if cancelled then return end
            push_job = pushAdded(source, remote, nil, report, function(pushed)
                if cancelled then return end
                cb({ pulled = 0, pushed = deleted_n + pushed, hidden = 0, conflicts = 0, skipped = false })
            end)
        end)
        return handle
    end

    --- 拉远端书架；list 为映射后的书籍列表。
    ---@param next_step fun(books: Book[])
    local function pull(next_step)
        report(_("正在拉取书架…"))
        job = remote:shelfSyncAsync(function(wire, err)
            if cancelled then return end
            if not wire then cb(nil, err); return end
            next_step(shelf_list(wire, on_cover).data or {})
        end)
    end
    ---@param books Book[]
    ---@param pushed integer
    local function reconcile(books, pushed)
        report(T(_("正在写入书架（%1 本）"), #books))
        local result, err = Shelf.reconcile(source.id, books)
        if not result then cb(nil, err); return end
        result.pushed = pushed
        cb(result)
    end

    delete_job = pushDeleted(source, remote, report, function(deleted_n)
        if cancelled then return end
        pull(function(books)
            local remote_ids = {}
            for _idx, book in ipairs(books) do
                if book.stable_id then remote_ids[tostring(book.stable_id)] = true end
            end
            push_job = pushAdded(source, remote, remote_ids, report, function(pushed)
                if cancelled then return end
                local total = deleted_n + pushed
                if pushed == 0 then
                    reconcile(books, total)
                    return
                end
                pull(function(fresh) reconcile(fresh, total) end)
            end)
        end)
    end)
    return handle
end

--- 删除：本地先标 deleted 立即回调，能上网时再推云端真删；推送失败留墓碑待同步重试。
---@param source SourceBase
---@param remote table 书架远端（见模块头注释）
---@param identity BookIdentity
---@param cb fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }
function Shelf.deleteAsync(source, remote, identity, cb)
    local Store = require("book.store")
    if not Store.markDeleted(source.id, identity.stable_id) then
        require("ui/uimanager"):nextTick(function()
            cb(false, _("删除本书失败"))
        end)
        return { cancel = function() end }
    end
    local cancelled, job = false, nil
    require("ui/uimanager"):nextTick(function()
        if not cancelled then cb(true) end
    end)
    require("ui/network/manager"):runWhenOnline(function()
        if cancelled then return end
        job = remote:removeFromShelfAsync(identity.stable_id, function(wire)
            if cancelled then return end
            if wire then require("book.books_db").remove(source.id, identity.stable_id) end
        end)
    end)
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job.cancel() end
    end }
end

return Shelf
