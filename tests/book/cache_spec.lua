--[[--
book.cache：协作式异步扫盘/删除状态机

purgeDirAsync 是 cache.lua 的局部函数，只能经 clearAsync 触达；
DB 清理同步完成后 purge 走 nextTick 分片调度，由 Stubs.flush() 驱动。
BookDB/ChapterDB 全部假实现（内存表），绝不打开真实的 book.sqlite3；
临时目录限定在沙箱 .moon/cache/test_book_cache_spec/ 下，结束清理。

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

local db_log -- 记录 db 路径清理调用
local book_rows -- 假 books 路径登记（path 非空的行）
local chapter_rows -- 假 chapters 表

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
    db_log = {
        book_clear_under = {},
        chapter_delete_under = {},
    }
    book_rows = {}
    chapter_rows = {}
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
        bookWorkDir = function(stable_id, id)
            return CACHE .. "/" .. id .. "/book/" .. stable_id
        end,
        coverPath = function(stable_id, id)
            return CACHE .. "/" .. id .. "/image/" .. stable_id .. ".png"
        end,
    }
end

package.preload["utils.log"] = function()
    return { info = function() end, warn = function() end }
end
package.loaded["utils.log"] = nil

-- 假 BookDB：clearPathsUnder 只把行从登记表里摘掉（真实实现是 path 置 NULL）
package.preload["db.book"] = function()
    local function removeWhere(pred)
        for i = #book_rows, 1, -1 do
            if pred(book_rows[i]) then
                table.remove(book_rows, i)
            end
        end
    end
    return {
        clearPathsUnder = function(dir)
            db_log.book_clear_under[#db_log.book_clear_under + 1] = dir
            local prefix = dir .. "/"
            removeWhere(function(row)
                return row.path and row.path:sub(1, #prefix) == prefix
            end)
            return true
        end,
    }
end

package.preload["db.chapter"] = function()
    return {
        deleteUnder = function(dir)
            db_log.chapter_delete_under[#db_log.chapter_delete_under + 1] = dir
            local prefix = dir .. "/"
            for i = #chapter_rows, 1, -1 do
                if chapter_rows[i].path:sub(1, #prefix) == prefix then
                    table.remove(chapter_rows, i)
                end
            end
            return true
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
    book_rows = {
        { source_id = "moon", stable_id = "aaa", path = CACHE .. "/moon/book/aaa/1.html", updated_at = os.time() },
        { source_id = "local", stable_id = "/books/local.epub", path = "/books/local.epub", title = "本地书" },
    }
    chapter_rows = {
        { path = CACHE .. "/moon/book/aaa/sub/2.html", source_id = "moon", stable_id = "aaa", chapter_idx = 2 },
    }

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
    -- 只清 cache 内的路径登记；本地书路径与元数据不是缓存。
    Assert.contains(db_log.chapter_delete_under, CACHE)
    Assert.contains(db_log.book_clear_under, CACHE)
    Assert.eq(#book_rows, 1)
    Assert.eq(book_rows[1].path, "/books/local.epub")
    Assert.eq(book_rows[1].title, "本地书")
    Assert.eq(#chapter_rows, 0)
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
    Assert.contains(db_log.chapter_delete_under, CACHE) -- 文件失败前 DB 路径登记已清
    Assert.contains(db_log.book_clear_under, CACHE)
    Assert.eq(lfs.attributes(CACHE, "mode"), "directory") -- 失败后仍重建空根
end

-- ── 收尾：清临时树 + 还原打桩，别污染后续 spec ─────────
resetTree()
if lfs.attributes(BASE) then
    ffiUtil.purgeDir(BASE)
end
for _, name in ipairs({
    "utils.paths",
    "db.book",
    "db.chapter",
    "ui.components.image",
    "book.cache",
}) do
    package.preload[name] = nil
    package.loaded[name] = nil
end
