--[[--
缓存文件管理：扫盘统计、过期清理、整库清空。

  只管 `.moon/cache/` 下的落盘文件与对应 books/chapters 路径登记；
  书籍身份与元数据门面在 book.store。

@module koplugin.book.book.cache
--]]

local lfs = require("libs/libkoreader-lfs")
local logger = require("utils.log")
local UIManager = require("ui/uimanager")
local Paths = require("utils.paths")
local BookDB = require("db.book")
local ChapterDB = require("db.chapter")
local ProgressDB = require("db.progress")

local Cache = {}

local META_TTL = 7 * 24 * 60 * 60
local LOCAL_BOOK_TTL = 90 * 24 * 60 * 60

--- path 的父目录
---@param path string
---@return string|nil
local function parentDir(path)
    return path:match("(.+)/[^/]+$")
end

--- 目录直属子项（跳过 . / ..）。
---@param dir string
---@return string[]
local function entriesOf(dir)
    local names = {}
    for name in lfs.dir(dir) do
        if name ~= "." and name ~= ".." then names[#names + 1] = name end
    end
    return names
end

--- 缓存根下所有 <source>/book/<entry> 的绝对路径。
---@param cache_root string
---@return string[]
local function bookEntries(cache_root)
    local out = {}
    for _, source_name in ipairs(entriesOf(cache_root)) do
        local book_root = cache_root .. "/" .. source_name .. "/book"
        if lfs.attributes(book_root, "mode") == "directory" then
            for _, name in ipairs(entriesOf(book_root)) do
                out[#out + 1] = book_root .. "/" .. name
            end
        end
    end
    return out
end

--- 条目最后活跃时间：有阅读进度取其更新时间，否则回退文件 mtime。
---@param path string
---@param recorded number|nil
---@return number
local function lastActivityOf(path, recorded)
    if recorded and recorded > 0 then return recorded end
    local attr = lfs.attributes(path)
    return attr and tonumber(attr.modification) or 0
end

--- 删掉一个过期条目并清对应登记：目录 = 章节书（整目录 purge），文件 = 整本书。
---@param path string
---@param mode string
---@return boolean removed
local function purgeEntry(path, mode)
    if mode == "directory" then
        if not require("ffi/util").purgeDir(path) then return false end
        BookDB.clearPathsUnder(path)
        ChapterDB.deleteUnder(path)
        logger.info("book cleaned stale book dir", path)
        return true
    end
    -- os.remove 失败返回 nil, err 不抛错
    if not os.remove(path) then return false end
    BookDB.clearPath(path)
    ChapterDB.delete(path)
    return true
end

--- 清理过期 meta，并删掉连续 90 天未打开的书目录；顺带清失效路径登记
---@return number 删除的目录/文件数
function Cache.cleanupStale()
    Paths.ensureCacheRoot()
    local now = os.time()
    BookDB.expireBefore(now - META_TTL)

    local book_rows = BookDB.pathsAll()
    local chapter_rows = ChapterDB.all()
    local progress_by_book = {}
    local loaded_sources = {}
    for _, row in ipairs(book_rows) do
        if not loaded_sources[row.source_id] then
            loaded_sources[row.source_id] = true
            for _, progress in ipairs(ProgressDB.all(row.source_id)) do
                progress_by_book[row.source_id .. "\0" .. progress.stable_id] =
                    tonumber(progress.updated_at) or 0
            end
        end
    end
    -- 活跃度按条目路径索引：整本书 = 文件自身；章节书 = 章节所在目录取最大值。
    local activity_by_path = {}
    for _, row in ipairs(book_rows) do
        local activity = progress_by_book[row.source_id .. "\0" .. row.stable_id] or 0
        activity_by_path[row.path] = math.max(activity_by_path[row.path] or 0, activity)
        local dir = parentDir(row.path)
        if dir then
            activity_by_path[dir] = math.max(activity_by_path[dir] or 0, activity)
        end
    end

    local removed = 0
    for _, path in ipairs(bookEntries(Paths.cacheDir())) do
        local mode = lfs.attributes(path, "mode")
        local activity = lastActivityOf(path, activity_by_path[path])
        if (mode == "directory" or mode == "file")
            and activity > 0 and now - activity >= LOCAL_BOOK_TTL
            and purgeEntry(path, mode) then
            removed = removed + 1
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

--- 过期缓存清理推到下一 tick 在主进程跑：cleanupStale 读写 sqlite，
--- 而 db.base 禁止在 fork 子进程里碰库（子进程会继承父进程的连接句柄）。
---@param cb fun(ok: boolean, removed: number|nil)|nil
---@return { cancel: fun() }
function Cache.cleanupStaleAsync(cb)
    cb = cb or function() end
    local cancelled = false
    UIManager:nextTick(function()
        if cancelled then return end
        local ok, result = pcall(Cache.cleanupStale)
        if not ok then
            logger.warn("book cache cleanup failed", result)
            cb(false)
            return
        end
        cb(true, result)
    end)
    return { cancel = function() cancelled = true end }
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

    --- 回调最终结果；已取消的任务静默丢弃结果。
    ---@param ok boolean
    ---@param err any 失败时为 os.remove 的错误串
    local function finish(ok, err)
        if not cancelled then
            done(ok, err)
        end
    end
    --- 一个 UI 周期最多处理 24 个目录项，剩余工作排到下一 tick。
    --- 栈顶目录迭代完才删自身（自底向上），任一 remove 失败立即终止整次删除。
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
    --- 扫描收尾：缓存目录字节数之外再计入 sqlite 库文件本身，然后回调总量。
    local function finish()
        local db_file = Paths.dbPath()
        if lfs.attributes(db_file, "mode") == "file" then
            total = total + (tonumber(lfs.attributes(db_file, "size") or 0) or 0)
        end
        if not cancelled then
            cb(total)
        end
    end
    --- 一个 UI 周期最多 stat 48 个目录项，累加文件大小后排下一 tick。
    --- 无法 stat 的项直接跳过，不中断扫描（大小统计允许不精确）。
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
    -- 先清 DB 再删文件：即使文件删除失败，DB 记录已干净，不会产生孤立引用。
    -- db.* 不抛错，失败只体现在返回值上。
    if not (ChapterDB.clear() and BookDB.clearPaths() and BookDB.stripMeta()) then
        logger.warn("book cache db clear failed, skipping file purge")
        cb(false, "db clear failed")
        return { cancel = function() end }
    end
    -- DB 清理成功后再删文件
    purge_job = purgeDirAsync(dir, function(ok, err)
        if cancelled then return end
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
    return {
        cancel = function()
            cancelled = true
            if purge_job then
                purge_job:cancel()
            end
        end,
    }
end

return Cache
