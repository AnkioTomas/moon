--[[--
book.cache：协作式异步扫盘/删除状态机 + cleanupStale TTL 判定

purgeDirAsync 是 cache.lua 的局部函数，只能经 clearAsync 触达；
这里把 utils.task 打成「主进程同步跑 worker + 同步 on_done」，
避免真 fork 子进程，同时保留 purge 自身的 nextTick 分片调度。
db 三件套全部假实现（内存表），绝不打开真实 config/.moon/book.sqlite3；
临时目录限定在 config/.moon/cache/test_book_cache_spec/ 下，结束清理。

@module tests.book.cache_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
local Config = require("support.config")
local lfs = require("libs/libkoreader-lfs")
local ffiUtil = require("ffi/util")

local BASE = Config.dir() .. "/.moon/cache/test_book_cache_spec"
local CACHE = BASE .. "/cache"
local DB_FILE = BASE .. "/book.sqlite3" -- 假文件：只被 lfs.attributes 统计大小，绝不打开

local db_log -- 记录 db 调用：open/expire_before/strip_meta/clear/deleted
local open_rows -- 假 opens 表

-- ── 文件系统小工具 ──────────────────────────────────────
local function mkdirs(path)
    if lfs.attributes(path, "mode") == "directory" then
        return
    end
    local parent = path:match("(.+)/[^/]+$")
    if parent then
        mkdirs(parent)
    end
    lfs.mkdir(path)
end

local function writeFile(path, bytes)
    local parent = path:match("(.+)/[^/]+$")
    if parent then
        mkdirs(parent)
    end
    local fh = assert(io.open(path, "wb"))
    fh:write(string.rep("x", bytes))
    fh:close()
end

--- 清掉临时树（含上轮失败留下的只读目录）并重置假 db 状态
local function resetTree()
    os.execute("chmod -R u+w " .. BASE .. " 2>/dev/null")
    if lfs.attributes(BASE) then
        ffiUtil.purgeDir(BASE)
    end
    mkdirs(CACHE)
    db_log = { deleted = {} }
    open_rows = {}
end

-- ── 打桩：paths 指向临时树；task 不 fork；db 全内存 ─────
package.preload["utils.paths"] = function()
    return {
        cacheDir = function()
            return CACHE
        end,
        dbPath = function()
            return DB_FILE
        end,
        ensureCacheRoot = function()
            mkdirs(CACHE)
        end,
    }
end

package.preload["utils.task"] = function()
    return {
        inSubProcess = function()
            return false
        end,
        -- 同步跑 worker + 同步 on_done：clearAsync 随即启动 purgeDirAsync，
        -- purge 的分片仍走 UIManager:nextTick，由 Stubs.flush() 驱动
        run = function(worker, opts)
            opts = opts or {}
            worker(0, nil)
            if opts.on_done then
                opts.on_done(nil)
            end
            return { abort = function() end }
        end,
    }
end

package.preload["utils.db.base"] = function()
    return {
        open = function()
            db_log.open = (db_log.open or 0) + 1
            return {}
        end,
        close = function() end,
    }
end

package.preload["utils.db.book"] = function()
    return {
        expireBefore = function(ts)
            db_log.expire_before = ts
        end,
        stripMeta = function()
            db_log.strip_meta = (db_log.strip_meta or 0) + 1
        end,
    }
end

package.preload["utils.db.open"] = function()
    return {
        all = function()
            return open_rows
        end,
        delete = function(source_id, stable_id)
            db_log.deleted[#db_log.deleted + 1] = source_id .. "/" .. stable_id
            for i, row in ipairs(open_rows) do
                if row.source_id == source_id and row.stable_id == stable_id then
                    table.remove(open_rows, i)
                    break
                end
            end
        end,
        clear = function()
            db_log.clear = (db_log.clear or 0) + 1
            open_rows = {}
        end,
    }
end

package.loaded["book.cache"] = nil
local Cache = require("book.cache")

-- ── sizeBytesAsync：递归统计 + 含 db 文件大小 ───────────
do
    resetTree()
    writeFile(CACHE .. "/moon/book/aaa/1.html", 100)
    writeFile(CACHE .. "/moon/book/aaa/sub/2.html", 50)
    writeFile(CACHE .. "/moon/image/cover.png", 30)
    writeFile(DB_FILE, 17)

    local got
    Cache.sizeBytesAsync(function(n)
        got = n
    end)
    Assert.is_nil(got) -- flush 前不得回调
    Stubs.flush()
    Assert.eq(got, 197) -- 100+50+30+17
end

-- ── sizeBytesAsync：空树且无 db 文件 → 0 ───────────────
do
    resetTree()
    local got
    Cache.sizeBytesAsync(function(n)
        got = n
    end)
    Stubs.flush()
    Assert.eq(got, 0)
end

-- ── sizeBytesAsync：cancel 后不再回调 ──────────────────
do
    resetTree()
    writeFile(CACHE .. "/moon/book/aaa/1.html", 10)
    local got
    local job = Cache.sizeBytesAsync(function(n)
        got = n
    end)
    job.cancel()
    Stubs.flush()
    Assert.is_nil(got)
    Assert.eq(lfs.attributes(CACHE .. "/moon/book/aaa/1.html", "mode"), "file") -- 未误删
end

-- ── clearAsync→purgeDirAsync：递归删除 + db 先清 + 根目录重建 ──
do
    resetTree()
    writeFile(CACHE .. "/moon/book/aaa/1.html", 10)
    writeFile(CACHE .. "/moon/book/aaa/sub/2.html", 10)
    writeFile(CACHE .. "/moon/image/c.png", 10)

    local called, ok_result = false, nil
    Cache.clearAsync(function(ok)
        called = true
        ok_result = ok
    end)
    Assert.is_false(called) -- purge 步骤排队在 nextTick
    Assert.eq(lfs.attributes(CACHE .. "/moon/book/aaa/sub/2.html", "mode"), "file")
    Stubs.flush()
    Assert.is_true(called)
    Assert.is_true(ok_result)
    Assert.is_nil(lfs.attributes(CACHE .. "/moon")) -- 整树被删
    Assert.eq(lfs.attributes(CACHE, "mode"), "directory") -- ensureCacheRoot 重建空根
    Assert.eq(db_log.clear, 1)
    Assert.eq(db_log.strip_meta, 1)
end

-- ── purgeDirAsync：条目超过单步 budget=24，靠 nextTick 续跑 ──
do
    resetTree()
    for i = 1, 40 do
        writeFile(CACHE .. ("/moon/book/many/f%02d.html"):format(i), 1)
    end

    local UIManager = require("ui/uimanager")
    local orig_nextTick = UIManager.nextTick
    local ticks = 0
    UIManager.nextTick = function(self, fn)
        ticks = ticks + 1
        return orig_nextTick(self, fn)
    end

    local done
    Cache.clearAsync(function(ok)
        done = ok
    end)
    Stubs.flush()
    UIManager.nextTick = orig_nextTick

    Assert.is_true(done)
    Assert.is_nil(lfs.attributes(CACHE .. "/moon"))
    -- 42 个文件条目 + 各级 "." ".." 超过 24，必须多次调度才能跑完
    Assert.is_true(ticks >= 2)
end

-- ── purgeDirAsync：cancel 后一步都不删 ──────────────────
do
    resetTree()
    writeFile(CACHE .. "/moon/book/aaa/1.html", 10)
    local called = false
    local handle = Cache.clearAsync(function()
        called = true
    end)
    handle.cancel() -- task stub 同步 on_done，此时 purge 第一步已排队
    Stubs.flush()
    Assert.is_false(called)
    Assert.eq(lfs.attributes(CACHE .. "/moon/book/aaa/1.html", "mode"), "file")
end

-- ── purgeDirAsync：删除失败走错误回调（只读目录让 os.remove 失败）──
do
    resetTree()
    writeFile(CACHE .. "/moon/book/broken/x.html", 10)
    os.execute("chmod 0555 " .. CACHE .. "/moon/book/broken")

    local called, ok_result, err_result = false, nil, nil
    Cache.clearAsync(function(ok, err)
        called = true
        ok_result = ok
        err_result = err
    end)
    Stubs.flush()
    os.execute("chmod -R u+w " .. BASE .. " 2>/dev/null") -- 先恢复，别污染后续用例

    Assert.is_true(called)
    Assert.is_false(ok_result)
    Assert.not_nil(err_result)
    Assert.eq(db_log.clear, 1) -- 文件失败前 db 已清
    Assert.eq(lfs.attributes(CACHE, "mode"), "directory") -- 失败后仍重建空根
end

-- ── cleanupStale：90 天 TTL 判定 + 失效 opens 清理 ──────
do
    resetTree()
    local now = os.time()
    local TTL = 90 * 24 * 60 * 60
    writeFile(CACHE .. "/moon/book/oldbook/1.html", 10)
    writeFile(CACHE .. "/moon/book/newbook/1.html", 10)
    writeFile(CACHE .. "/moon/book/norecord/1.html", 10)
    writeFile(CACHE .. "/moon/book/loose.epub", 10)
    open_rows = {
        { source_id = "moon", stable_id = "old", path = CACHE .. "/moon/book/oldbook/1.html", last_open = now - TTL - 86400 },
        { source_id = "moon", stable_id = "new", path = CACHE .. "/moon/book/newbook/1.html", last_open = now - 3600 },
        { source_id = "moon", stable_id = "loose", path = CACHE .. "/moon/book/loose.epub", last_open = now - TTL - 86400 },
        { source_id = "moon", stable_id = "ghost", path = CACHE .. "/moon/book/ghost/1.html", last_open = now - 100 },
    }

    local removed = Cache.cleanupStale()

    Assert.eq(removed, 2) -- oldbook 目录 + loose.epub 散文件
    Assert.is_nil(lfs.attributes(CACHE .. "/moon/book/oldbook"))
    Assert.is_nil(lfs.attributes(CACHE .. "/moon/book/loose.epub"))
    Assert.eq(lfs.attributes(CACHE .. "/moon/book/newbook", "mode"), "directory") -- 近期打开不删
    Assert.eq(lfs.attributes(CACHE .. "/moon/book/norecord", "mode"), "directory") -- 无记录回退 mtime（新建）不删

    -- meta 过期用 7 天 TTL
    Assert.not_nil(db_log.expire_before)
    Assert.is_true(math.abs((now - db_log.expire_before) - 7 * 24 * 60 * 60) <= 2)

    -- 失效 opens：ghost 路径不存在被清；loose/old 文件已删，记录同样被清
    Assert.contains(db_log.deleted, "moon/ghost")
    Assert.contains(db_log.deleted, "moon/loose")
    Assert.contains(db_log.deleted, "moon/old")
    Assert.eq(#open_rows, 1)
    Assert.eq(open_rows[1].stable_id, "new") -- 唯一存活的 opens 记录
end

-- ── cleanupStale：全新鲜 → 0，不删任何 opens ────────────
do
    resetTree()
    writeFile(CACHE .. "/moon/book/fresh/1.html", 10)
    open_rows = {
        { source_id = "moon", stable_id = "fresh", path = CACHE .. "/moon/book/fresh/1.html", last_open = os.time() },
    }
    local removed = Cache.cleanupStale()
    Assert.eq(removed, 0)
    Assert.eq(lfs.attributes(CACHE .. "/moon/book/fresh", "mode"), "directory")
    Assert.eq(#db_log.deleted, 0)
    Assert.eq(#open_rows, 1)
end

-- ── 收尾：清临时树 + 还原打桩，别污染后续 spec ─────────
resetTree()
if lfs.attributes(BASE) then
    ffiUtil.purgeDir(BASE)
end
for _, name in ipairs({
    "utils.paths",
    "utils.task",
    "utils.db.base",
    "utils.db.book",
    "utils.db.open",
    "book.cache",
}) do
    package.preload[name] = nil
    package.loaded[name] = nil
end
