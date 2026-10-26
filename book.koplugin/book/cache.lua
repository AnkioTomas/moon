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
local BookDB = require("book.books_db")
local ChapterDB = require("book.chapters_db")

local Cache = {}

local BUDGET = 32

--- 协作式递归遍历：一个 UI 周期最多处理 BUDGET 个目录项，剩余排到下一 tick。
--- 文件在遇到时回调，目录在其子项全部处理完后回调（自底向上，便于删除）。
--- protected 返回 true 的目录整体保留：不进入、不删（清理时保住 KOReader 的 `.sdr` 边车）。
--- visit 返回 false/nil 时立即终止，done(false, err)。
---@param root string
---@param visit fun(path: string, attr: table): boolean|nil, string|nil
---@param done fun(ok: boolean, err: string|nil)
---@param protected (fun(path: string, attr: table): boolean|nil)|nil
---@return { cancel: fun() }
local function walkAsync(root, visit, done, protected)
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
                    if not (protected and protected(path, attr)) then
                        push(path, attr)
                    end
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
            UIManager:nextTick(require("ui.guard").wrap("book cache", step))
        end
    end
    UIManager:nextTick(require("ui.guard").wrap("book cache", step))
    return { cancel = function() cancelled = true end }
end

--- 同步递归遍历，只给子进程用（主线程禁用：大目录会卡 UI）；visit 只收文件。
---@param root string
---@param visit fun(path: string, attr: table)
function Cache.walkFiles(root, visit)
    local stack = { root }
    while #stack > 0 do
        local dir = table.remove(stack)
        local iter, state = lfs.dir(dir)
        if type(iter) == "function" then
            for name in iter, state do
                if name ~= "." and name ~= ".." then
                    local path = dir .. "/" .. name
                    local attr = lfs.attributes(path)
                    if attr and attr.mode == "directory" then
                        stack[#stack + 1] = path
                    elseif attr then
                        visit(path, attr)
                    end
                end
            end
        end
    end
end

--- 缓存体积统计：几千个文件的遍历放子进程，不占主线程；再计入 sqlite 库文件本身。
---@param cb fun(bytes: number)
---@return { cancel: fun() }
function Cache.sizeBytesAsync(cb)
    local cache_dir, db_path = Paths.cacheDir(), Paths.dbPath()
    return require("workers.job").run(function()
        local total = 0
        Cache.walkFiles(cache_dir, function(_path, attr) total = total + (tonumber(attr.size) or 0) end)
        local db_attr = lfs.attributes(db_path)
        if db_attr and db_attr.mode == "file" then total = total + (tonumber(db_attr.size) or 0) end
        return total
    end, {
        name = "cache.size", kind = "light",
        on_done = cb,
        on_failed = function(err)
            logger.warn("book cache size failed", err)
            cb(0)
        end,
    })
end

--- 后台分 tick 删除一个已脱离书库的目录（删书时改名移走的工作目录）；失败只记日志。
---@param dir string
function Cache.purgeAsync(dir)
    walkAsync(dir, function(path) return os.remove(path) end, function(ok, err)
        if not ok then logger.warn("book cache trash purge failed", dir, err) end
    end)
end

--- KOReader 的 `.sdr` 边车目录名：去掉最后一个后缀再加 `.sdr`（`book.epub` → `book.sdr`）。
---@param path string
---@return boolean
local function isSidecarDir(path)
    return path:match("[^/]+%.sdr$") ~= nil
end

--- 清空文件缓存及其路径登记，不动书籍元数据。
--- KOReader 的 `.sdr` 边车（阅读位置、书签、标注）就落在正文文件旁边，属于用户数据而非
--- 「可重新生成的缓存」，这里整体保留：清理后重下到同一路径，位置与标注原样回来。
---@param cb fun(ok: boolean, err: any)|nil
---@return { cancel: fun() }
function Cache.clearAsync(cb)
    cb = cb or function() end
    local dir = Paths.cacheDir()
    local cancelled = false
    local purge_job
    --- 保留下来的边车目录；用于判断某个目录删不掉是不是「只剩边车」，是就不算失败。
    local kept_sidecars = {}
    local trash_prefix = dir .. "/.trash/"
    ---@param path string
    ---@return boolean
    local function keepsSidecar(path)
        local prefix = path .. "/"
        for _idx, kept in ipairs(kept_sidecars) do
            if kept:sub(1, #prefix) == prefix then return true end
        end
        return false
    end
    -- 只清 cache 目录下的路径登记；本地源外部文件路径与书籍元数据必须保留。
    -- 先清 DB 再删文件：即使文件删除失败，DB 记录已干净，不会产生孤立引用。
    -- db.* 不抛错，失败只体现在返回值上。
    -- 本地源扫盘索引里的「试过补封面」标记也要清：封面就在 cache 里，不清的话扫盘认为已试过、永不重新提取。
    if not (ChapterDB.deleteUnder(dir) and BookDB.clearPathsUnder(dir)
        and require("source.local.scan_db").resetCovers()) then
        logger.warn("book cache db clear failed, skipping file purge")
        cb(false, "db clear failed")
        return { cancel = function() end }
    end
    -- DB 清理成功后再删文件。
    -- 单条文件 remove 失败立即终止；目录失败例外——里面可能只剩受保护的 `.sdr` 边车。
    purge_job = walkAsync(dir, function(path, attr)
        if attr.mode == "directory" then
            if os.remove(path) then return true end
            return keepsSidecar(path)
        end
        return os.remove(path)
    end, function(ok, err)
        if cancelled then return end
        if not ok then
            -- 文件删除失败但 DB 已清：重建 cache 目录即可
            Paths.ensureCacheRoot()
            logger.warn("book cache file purge failed (db already cleared)", dir, err)
            cb(false, err)
            return
        end
        Paths.ensureCacheRoot()
        -- 内存侧随磁盘一起作废：位图缓存与下载失败退避，封面按需重新下载 / 提取。
        require("ui.themes.widgets.image.core").invalidateAll()
        require("ui.themes.widgets.image.download").resetFailed()
        logger.info("book cache cleared", dir)
        cb(true)
    end, function(path)
        -- .trash 里的边车是删书留下的，跟着垃圾一起清掉，不保留。
        if path:sub(1, #trash_prefix) == trash_prefix then return false end
        if isSidecarDir(path) then
            kept_sidecars[#kept_sidecars + 1] = path
            return true
        end
        return false
    end)
    return { cancel = function()
            cancelled = true
            if purge_job then
                purge_job:cancel()
            end
        end }
end

return Cache
