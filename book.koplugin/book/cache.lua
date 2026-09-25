--[[--
缓存文件管理：扫盘统计、整库清空。

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

local Cache = {}

local BUDGET = 32

--- 协作式递归遍历：一个 UI 周期最多处理 BUDGET 个目录项，剩余排到下一 tick。
--- 文件在遇到时回调，目录在其子项全部处理完后回调（自底向上，便于删除）。
--- visit 返回 false/nil 时立即终止，done(false, err)。
---@param root string
---@param visit fun(path: string, attr: table): boolean|nil, string|nil
---@param done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }
local function walkAsync(root, visit, done)
    local cancelled = false
    local stack = {}
    --- lfs.dir 返回 (iter, dir_obj)；必须成对保存，调用 iter(dir_obj)。
    local function push(path, attr)
        local iter, state = lfs.dir(path)
        if type(iter) == "function" and state ~= nil then
            stack[#stack + 1] = { path = path, attr = attr, iter = iter, state = state }
        end
    end
    local root_attr = lfs.attributes(root)
    if root_attr and root_attr.mode == "directory" then push(root, root_attr) end

    local function step()
        if cancelled then return end
        for _ = 1, BUDGET do
            local top = stack[#stack]
            if not top then break end
            local name = top.iter(top.state)
            local ok, err = true, nil
            if not name then
                table.remove(stack)
                ok, err = visit(top.path, top.attr)
            elseif name ~= "." and name ~= ".." then
                local path = top.path .. "/" .. name
                local attr = lfs.attributes(path)
                if attr and attr.mode == "directory" then
                    push(path, attr)
                elseif attr then
                    ok, err = visit(path, attr)
                end
            end
            if not ok then
                done(false, err)
                return
            end
        end
        if #stack == 0 then
            done(true)
        else
            UIManager:nextTick(step)
        end
    end
    UIManager:nextTick(step)
    return { cancel = function() cancelled = true end }
end

--- Cooperative cache size scan. Never walk the cache tree during widget build.
--- 缓存目录字节数之外再计入 sqlite 库文件本身；无法 stat 的项直接跳过。
---@param cb fun(bytes: number)
---@return { cancel: fun() }
function Cache.sizeBytesAsync(cb)
    local total = 0
    return walkAsync(Paths.cacheDir(), function(_, attr)
        if attr.mode == "file" then total = total + (tonumber(attr.size) or 0) end
        return true
    end, function()
        local db_attr = lfs.attributes(Paths.dbPath())
        if db_attr and db_attr.mode == "file" then
            total = total + (tonumber(db_attr.size) or 0)
        end
        cb(total)
    end)
end

--- 清空文件缓存及其路径登记，不动书籍元数据。
---@param cb fun(ok: boolean, err: any)|nil
---@return { cancel: fun() }
function Cache.clearAsync(cb)
    cb = cb or function() end
    local dir = Paths.cacheDir()
    local cancelled = false
    local purge_job
    -- 只清 cache 目录下的路径登记；本地源外部文件路径与书籍元数据必须保留。
    -- 先清 DB 再删文件：即使文件删除失败，DB 记录已干净，不会产生孤立引用。
    -- db.* 不抛错，失败只体现在返回值上。
    if not (ChapterDB.deleteUnder(dir) and BookDB.clearPathsUnder(dir)) then
        logger.warn("book cache db clear failed, skipping file purge")
        cb(false, "db clear failed")
        return { cancel = function() end }
    end
    -- DB 清理成功后再删文件
    -- 任一 remove 失败立即终止整次删除。
    purge_job = walkAsync(dir, function(path) return os.remove(path) end, function(ok, err)
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
    return { cancel = function()
            cancelled = true
            if purge_job then
                purge_job:cancel()
            end
        end }
end

return Cache
