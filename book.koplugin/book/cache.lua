--[[--
缓存文件管理：扫盘统计、过期清理、整库清空。

  只管 `.moon/cache/` 下的落盘文件与对应 books/chapters 路径登记；
  书籍身份与元数据门面在 book.store。

@module koplugin.book.book.cache
--]]

local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local UIManager = require("ui/uimanager")
local Paths = require("utils.paths")
local BookDB = require("utils.db.book")
local ChapterDB = require("utils.db.chapter")
local Task = require("utils.task")

local Cache = {}

local META_TTL = 7 * 24 * 60 * 60
local LOCAL_BOOK_TTL = 90 * 24 * 60 * 60

--- path 的父目录
---@param path string
---@return string|nil
local function parentDir(path)
    return path:match("(.+)/[^/]+$")
end

--- 清理过期 meta，并删掉连续 90 天未打开的书目录；顺带清失效路径登记
---@return number 删除的目录/文件数
function Cache.cleanupStale()
    Paths.ensureCacheRoot()
    local now = os.time()
    BookDB.expireBefore(now - META_TTL)

    local book_rows = BookDB.pathsAll()
    local chapter_rows = ChapterDB.all()
    local book_by_path = {}
    -- 目录活跃度：章节 touch 也会更新 books.last_open，按书目录取最大值即可
    local last_open_by_dir = {}
    for _, row in ipairs(book_rows) do
        book_by_path[row.path] = row
        local dir = parentDir(row.path)
        if dir then
            last_open_by_dir[dir] = math.max(
                last_open_by_dir[dir] or 0,
                tonumber(row.last_open) or 0
            )
        end
    end
    local removed = 0
    local cache_root = Paths.cacheDir()

    for source_name in lfs.dir(cache_root) do
        if source_name ~= "." and source_name ~= ".." then
            local source_dir = cache_root .. "/" .. source_name
            if lfs.attributes(source_dir, "mode") == "directory" then
                local book_root = source_dir .. "/book"
                if lfs.attributes(book_root, "mode") == "directory" then
                    for name in lfs.dir(book_root) do
                        if name ~= "." and name ~= ".." then
                            local book_dir = book_root .. "/" .. name
                            local mode = lfs.attributes(book_dir, "mode")
                            if mode == "directory" then
                                local attr = lfs.attributes(book_dir)
                                local last_open = last_open_by_dir[book_dir]
                                    or (attr and tonumber(attr.modification)) or 0
                                if last_open > 0 and (now - last_open) >= LOCAL_BOOK_TTL then
                                    if require("ffi/util").purgeDir(book_dir) then
                                        removed = removed + 1
                                        BookDB.clearPathsUnder(book_dir)
                                        ChapterDB.deleteUnder(book_dir)
                                        logger.info("book cleaned stale book dir", book_dir)
                                    end
                                end
                            elseif mode == "file" then
                                local v = book_by_path[book_dir]
                                local last_open = v and tonumber(v.last_open) or 0
                                if last_open <= 0 then
                                    local attr = lfs.attributes(book_dir)
                                    last_open = attr and (tonumber(attr.modification) or 0) or 0
                                end
                                if last_open > 0 and (now - last_open) >= LOCAL_BOOK_TTL then
                                    -- os.remove 失败返回 nil, err 不抛错，pcall 恒真会误计数
                                    if os.remove(book_dir) then
                                        removed = removed + 1
                                        if v then
                                            BookDB.clearPath(book_dir)
                                        end
                                        ChapterDB.delete(book_dir)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- 登记了路径但文件已不存在 → 清登记
    for _, row in ipairs(book_rows) do
        local mode = lfs.attributes(row.path, "mode")
        if mode ~= "file" and mode ~= "directory" then
            BookDB.clearPath(row.path)
        end
    end
    for _, row in ipairs(chapter_rows) do
        if lfs.attributes(row.path, "mode") ~= "file" then
            ChapterDB.delete(row.path)
        end
    end
    return removed
end

--- 过期缓存清理放到子进程（扫盘 + SQLite）。
---@param cb fun(ok: boolean, removed: number|nil)|nil
---@return { cancel: fun() }
function Cache.cleanupStaleAsync(cb)
    cb = cb or function() end
    local ffiUtil = require("ffi/util")
    local task = Task.run(function(_, write_fd)
        ffiUtil.writeToFD(write_fd, tostring(Cache.cleanupStale()), true)
    end, {
        pipe = true,
        on_done = function(raw)
            cb(true, tonumber(raw) or 0)
        end,
        on_failed = function()
            cb(false)
        end,
    })
    return {
        cancel = function()
            task:abort()
        end,
    }
end

--- lfs.dir 返回 (iter, dir_obj)；必须成对保存，调用 iter(dir_obj)。
---@param path string
---@return { path: string, iter: fun(state: any): string|nil, state: any }|nil
local function pushDir(path)
    local iter, state = lfs.dir(path)
    if type(iter) ~= "function" or state == nil then
        return nil
    end
    return { path = path, iter = iter, state = state }
end

--- Cooperative recursive directory removal. Work is bounded per UI turn.
---@param dir string
---@param done fun(ok: boolean, err: any)
---@return { cancel: fun() }
local function purgeDirAsync(dir, done)
    local cancelled = false
    local stack = {}
    if lfs.attributes(dir, "mode") == "directory" then
        local entry = pushDir(dir)
        if entry then
            stack[1] = entry
        end
    end

    local function finish(ok, err)
        if not cancelled then
            done(ok, err)
        end
    end
    local function step()
        if cancelled then
            return
        end
        local budget = 24
        while budget > 0 and #stack > 0 do
            budget = budget - 1
            local top = stack[#stack]
            local name = top.iter(top.state)
            if not name then
                local ok, err = os.remove(top.path)
                table.remove(stack)
                if not ok then
                    finish(false, err)
                    return
                end
            elseif name ~= "." and name ~= ".." then
                local path = top.path .. "/" .. name
                local mode = lfs.attributes(path, "mode")
                if mode == "directory" then
                    local entry = pushDir(path)
                    if entry then
                        stack[#stack + 1] = entry
                    end
                elseif mode then
                    local ok, err = os.remove(path)
                    if not ok then
                        finish(false, err)
                        return
                    end
                end
            end
        end
        if #stack == 0 then
            finish(true)
        else
            UIManager:nextTick(step)
        end
    end
    UIManager:nextTick(step)
    return {
        cancel = function()
            cancelled = true
        end,
    }
end

--- Cooperative cache size scan. Never walk the cache tree during widget build.
---@param cb fun(bytes: number)
---@return { cancel: fun() }
function Cache.sizeBytesAsync(cb)
    local cancelled = false
    local total = 0
    local dir = Paths.cacheDir()
    local stack = {}
    if lfs.attributes(dir, "mode") == "directory" then
        local entry = pushDir(dir)
        if entry then
            stack[1] = entry
        end
    end
    local function finish()
        local db_file = Paths.dbPath()
        if lfs.attributes(db_file, "mode") == "file" then
            total = total + (tonumber(lfs.attributes(db_file, "size") or 0) or 0)
        end
        if not cancelled then
            cb(total)
        end
    end
    local function step()
        if cancelled then
            return
        end
        local budget = 48
        while budget > 0 and #stack > 0 do
            budget = budget - 1
            local top = stack[#stack]
            local name = top.iter(top.state)
            if not name then
                table.remove(stack)
            elseif name ~= "." and name ~= ".." then
                local path = top.path .. "/" .. name
                local attr = lfs.attributes(path)
                if attr and attr.mode == "directory" then
                    local entry = pushDir(path)
                    if entry then
                        stack[#stack + 1] = entry
                    end
                elseif attr and attr.mode == "file" then
                    total = total + (tonumber(attr.size) or 0)
                end
            end
        end
        if #stack == 0 then
            finish()
        else
            UIManager:nextTick(step)
        end
    end
    UIManager:nextTick(step)
    return {
        cancel = function()
            cancelled = true
        end,
    }
end

--- Clear file cache + 打开记录 without monopolising the UI thread.
---@param cb fun(ok: boolean, err: any)|nil
---@return { cancel: fun() }
function Cache.clearAsync(cb)
    cb = cb or function() end
    require("ui.components.image").abortPending()
    local dir = Paths.cacheDir()
    local cancelled = false
    local purge_job
    local db_job
    -- 先清 DB 再删文件：即使文件删除失败，DB 记录已干净，不会产生孤立引用
    db_job = Task.run(function()
        ChapterDB.clear()
        BookDB.clearOpens()
        BookDB.stripMeta()
    end, {
        on_done = function()
            if cancelled then
                return
            end
            -- DB 清理成功后再删文件
            purge_job = purgeDirAsync(dir, function(ok, err)
                if cancelled then
                    return
                end
                if not ok then
                    -- 文件删除失败但 DB 已清：重建 cache 目录即可
                    Paths.ensureCacheRoot()
                    logger.warn("book cache file purge failed (db already cleared)", dir, err)
                    cb(false, err)
                    return
                end
                Paths.ensureCacheRoot()
                logger.info("book cache cleared", dir)
                cb(true)
            end)
        end,
        on_failed = function(db_err)
            if cancelled then
                return
            end
            logger.warn("book cache db clear failed, skipping file purge", db_err)
            cb(false, db_err)
        end,
    })
    return {
        cancel = function()
            cancelled = true
            if purge_job then
                purge_job:cancel()
            end
            if db_job then
                db_job:abort()
            end
        end,
    }
end

return Cache
