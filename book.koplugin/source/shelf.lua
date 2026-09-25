--[[--
书架双向同步：本地删/加上行 + 远端快照 reconcile。

供有 add/remove 书架 API 的源（微信读书、京东读书）共用；源实例需提供
``id`` 与 ``_client``（``shelfSyncAsync`` / ``addToShelfAsync`` / ``removeFromShelfAsync``）。

@module koplugin.book.source.shelf
--]]

local logger = require("utils.log")
local _ = require("gettext")

local Shelf = {}

---@param job { cancel: fun() }|nil
local function cancel(job)
    if job and job.cancel then job:cancel() end
end

--- 逐本调用 ``source._client[method]`` 串行上行；on_ok 返回真才计入 pushed，失败只记日志继续下一本。
---@param source SourceBase
---@param ids string[]
---@param method string client 方法名
---@param on_ok fun(stable_id: string): boolean
---@param fail_log string 失败日志后缀
---@param cb fun(pushed: integer)
---@return { cancel: fun() }|nil
local function pushEach(source, ids, method, on_ok, fail_log, cb)
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
        local stable_id = ids[index]
        job = source._client[method](source._client, stable_id, function(wire, err)
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
---@param cb fun(pushed: integer)
---@return { cancel: fun() }|nil
local function pushDeleted(source, cb)
    local Store = require("book.store")
    return pushEach(source, require("db.book").pendingDeleteIds(source.id), "removeFromShelfAsync",
        function(stable_id)
            return Store.finalizeDeleted(source.id, stable_id)
        end, " shelf delete push failed", cb)
end

--- 本地新加架（脏行）上行。remote_ids 里已有的直接标已同步，不再发请求。
---@param source SourceBase
---@param remote_ids table<string, boolean>|nil
---@param cb fun(pushed: integer)
---@return { cancel: fun() }|nil
local function pushAdded(source, remote_ids, cb)
    local BookDB = require("db.book")
    local missing = {}
    for _, stable_id in ipairs(BookDB.pendingShelfAddIds(source.id)) do
        if remote_ids and remote_ids[stable_id] then
            BookDB.markSynced(source.id, stable_id)
        else
            missing[#missing + 1] = stable_id
        end
    end
    return pushEach(source, missing, "addToShelfAsync", function(stable_id)
        if not BookDB.markSynced(source.id, stable_id) then
            logger.warn(source.id .. " shelf mark synced failed", stable_id)
        end
        return true
    end, " shelf push failed", cb)
end

--- 书架同步。dirty_only：只推本地删/加，不拉书架、不对账；
--- 全量：先推删 → 拉远端 → 推本地新加 →（有推送则再拉）→ reconcile。
---@param source SourceBase
---@param opts { dirty_only?: boolean }|nil
---@param cb fun(result: SyncResult|nil, err: any)
---@param on_cover fun(stable_id: string, url: string) 书架列表里的封面 URL
---@param shelf_list fun(wire: table, on_cover: function): BookListResult 书架 wire 映射
---@return { cancel: fun() }
function Shelf.syncAsync(source, opts, cb, on_cover, shelf_list)
    local cancelled, job, push_job, delete_job = false, nil, nil, nil
    local handle = { cancel = function()
        cancelled = true
        cancel(job)
        cancel(push_job)
        cancel(delete_job)
    end }

    if opts and opts.dirty_only then
        delete_job = pushDeleted(source, function(deleted_n)
            if cancelled then return end
            push_job = pushAdded(source, nil, function(pushed)
                if cancelled then return end
                cb({ pulled = 0, pushed = deleted_n + pushed, hidden = 0, conflicts = 0, skipped = false })
            end)
        end)
        return handle
    end

    --- 拉远端书架；list 为映射后的书籍列表。
    ---@param next_step fun(books: Book[])
    local function pull(next_step)
        job = source._client:shelfSyncAsync(function(wire, err)
            if cancelled then return end
            if not wire then cb(nil, err); return end
            next_step(shelf_list(wire, on_cover).data or {})
        end)
    end
    ---@param books Book[]
    ---@param pushed integer
    local function reconcile(books, pushed)
        local result, err = require("book.store").reconcile(source.id, books)
        if not result then cb(nil, err); return end
        result.pushed = pushed
        cb(result)
    end

    delete_job = pushDeleted(source, function(deleted_n)
        if cancelled then return end
        pull(function(books)
            local remote_ids = {}
            for _, book in ipairs(books) do
                if book.stable_id then remote_ids[tostring(book.stable_id)] = true end
            end
            push_job = pushAdded(source, remote_ids, function(pushed)
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
---@param identity BookIdentity
---@param cb fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }
function Shelf.deleteAsync(source, identity, cb)
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
        job = source._client:removeFromShelfAsync(identity.stable_id, function(wire)
            if cancelled then return end
            if wire then Store.finalizeDeleted(source.id, identity.stable_id) end
        end)
    end)
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job.cancel() end
    end }
end

return Shelf
