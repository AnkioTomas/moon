--[[--
book.store BookRef 身份离线用例

@module tests.book.store_spec
--]]

local Assert = require("support.assert")
local BookRef = require("types.book").BookRef

-- stub db / paths / lfs 最小集（数据驱动：各用例块自行填表）
local lfs_modes = {} -- path → "file"/"directory"
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path, what)
            if what == "mode" then
                return lfs_modes[path]
            end
            return nil
        end,
        mkdir = function() return true end,
        dir = function() return function() end end,
    }
end

local Paths = require("utils.paths")
local orig_sanitize = Paths.sanitizeSourceId
local orig_ensure = Paths.ensureBookWork
local orig_work = Paths.bookWorkDir
local orig_split = Paths.splitBookWorkPath
Paths.ensureBookWork = function() end
Paths.bookWorkDir = function(stable_id, id)
    return "/tmp/" .. tostring(id) .. "/" .. tostring(stable_id)
end
-- 缓存工作目录识别由用例填表控制
local work_paths = {} -- path → { dir=, file= }
Paths.splitBookWorkPath = function(path)
    local hit = work_paths[path]
    if hit then
        return hit.dir, hit.file, hit.source_id, hit.slug
    end
    return nil
end

package.loaded["book.store"] = nil
package.loaded["utils.db.base"] = nil
package.loaded["utils.db.book"] = nil
package.loaded["utils.db.open"] = nil
package.preload["utils.db.base"] = function()
    return { open = function() return true end }
end
local book_rows = {} -- "sid\0stid" → books 行
local md5_index = {} -- "sid\0md5" → books 行
local stable_ids_by_source = {} -- source_id → stable_id[]
local open_paths = {} -- path → opens 行
local book_upserts = {}
local open_upserts = {}
package.preload["utils.db.book"] = function()
    return {
        get = function(source_id, stable_id)
            return book_rows[source_id .. "\0" .. tostring(stable_id)]
        end,
        getByMd5 = function(source_id, digest)
            return md5_index[source_id .. "\0" .. tostring(digest)]
        end,
        stableIdsBySource = function(source_id)
            return stable_ids_by_source[source_id] or {}
        end,
        upsert = function(row)
            book_upserts[#book_upserts + 1] = row
            return true
        end,
        expireBefore = function() end,
        stripMeta = function() end,
    }
end
package.preload["utils.db.open"] = function()
    return {
        upsert = function(row)
            open_upserts[#open_upserts + 1] = row
            return true
        end,
        get = function() return nil end,
        getByPath = function(path)
            return open_paths[path]
        end,
        all = function() return {} end,
        delete = function() end,
        clear = function() end,
    }
end
package.preload["utils.db.queue"] = function()
    return {
        -- 同步执行 worker：登记结果当断言即可见
        run = function(worker, opts)
            worker(nil)
            if opts and opts.on_done then
                opts.on_done(nil)
            end
        end,
        clear = function() end,
    }
end
-- partialMD5 由用例按路径填表控制
local md5_by_path = {}
package.preload["ffi/util"] = function()
    return {
        partialMD5 = function(path)
            return md5_by_path[path]
        end,
    }
end

local Store = require("book.store")

do
    local ref = BookRef.new("moon", "a.epub")
    local book = { ref = ref, title = "t", percent = 1 }
    local got = Store.refOf(book)
    Assert.eq(got.source_id, ref.source_id)
    Assert.eq(got.stable_id, ref.stable_id)
end

do
    Assert.is_nil(Store.refOf({ id = "legacy" }))
end

do
    Assert.eq(Store.bookFilePath("books/a.pdf", "webdav"), "/tmp/webdav/books/a.pdf/book.pdf")
    Assert.eq(Store.bookFilePath("books/a.unknown", "webdav"), "/tmp/webdav/books/a.unknown/book.epub")
end

-- ── identityFor：opens 快路径优先于缓存目录反查 ──────────
do
    open_paths["/x/book.epub"] = { source_id = "moon", stable_id = "s1", chapter_idx = 2 }
    -- 同时伪造缓存路径：opens 命中就必须赢
    work_paths["/x/book.epub"] = { dir = "/d1", file = "book.epub" }
    local id = Store.identityFor("/x/book.epub")
    Assert.eq(id.ref.source_id, "moon")
    Assert.eq(id.ref.stable_id, "s1")
    Assert.eq(id.chapter_idx, 2)
    open_paths["/x/book.epub"] = nil
    work_paths["/x/book.epub"] = nil
end

-- ── identityFor：缓存目录父级 slug 可反查 books（无 opens/伴生文件）──
do
    local path = "/cache/moon/book/slug/3.html"
    work_paths[path] = {
        dir = "/cache/moon/book/slug",
        file = "3.html",
        source_id = "moon",
        slug = Paths.slugFor("s-parent"),
    }
    stable_ids_by_source.moon = { "other", "s-parent" }
    local id = Store.identityFor(path)
    Assert.eq(id.ref.source_id, "moon")
    Assert.eq(id.ref.stable_id, "s-parent")
    Assert.eq(id.chapter_idx, 3)
    work_paths[path] = nil
    stable_ids_by_source.moon = nil
end

-- ── identityFor：缓存父级 slug 未命中 → nil（不回退本地书反查）──
do
    work_paths["/cache/moon/book/gone/1.html"] = { dir = "/cache/moon/book/gone", file = "1.html" }
    Assert.is_nil(Store.identityFor("/cache/moon/book/gone/1.html"))
    work_paths["/cache/moon/book/gone/1.html"] = nil
end

-- ── identityFor：本地书 filepath 直中 books ─────────────
do
    book_rows["local\0/lib/a.epub"] = { source_id = "local", stable_id = "/lib/a.epub", md5 = "m1" }
    local id = Store.identityFor("/lib/a.epub")
    Assert.eq(id.ref.source_id, "local")
    Assert.eq(id.ref.stable_id, "/lib/a.epub")
    Assert.is_nil(id.chapter_idx)
    book_rows["local\0/lib/a.epub"] = nil
end

-- ── identityFor：filepath 未中按内容 md5 反查（改名/移动）──
do
    md5_by_path["/lib/moved.epub"] = "digest-1"
    md5_index["local\0digest-1"] = { source_id = "local", stable_id = "/lib/original.epub" }
    local id = Store.identityFor("/lib/moved.epub")
    Assert.eq(id.ref.source_id, "local")
    Assert.eq(id.ref.stable_id, "/lib/original.epub") -- 用行里的 stable_id
    md5_by_path["/lib/moved.epub"] = nil
    md5_index["local\0digest-1"] = nil
end

-- ── ensureIdentity：命中已有身份 → 补 opens 记录（touchAsync）──
do
    open_paths["/lib/known.epub"] = { source_id = "moon", stable_id = "sk", chapter_idx = 5 }
    local id = Store.ensureIdentity("/lib/known.epub")
    Assert.eq(id.ref.stable_id, "sk")
    Assert.eq(id.chapter_idx, 5)
    Assert.eq(#open_upserts, 1)
    Assert.eq(open_upserts[1].source_id, "moon")
    Assert.eq(open_upserts[1].stable_id, "sk")
    Assert.eq(open_upserts[1].chapter_idx, 5)
    Assert.eq(open_upserts[1].path, "/lib/known.epub")
    open_paths["/lib/known.epub"] = nil
    open_upserts = {}
end

-- ── ensureIdentity：未入库本地文件 → 当 local 源书登记 ────
do
    lfs_modes["/lib/new.book.epub"] = "file"
    md5_by_path["/lib/new.book.epub"] = "digest-new"
    local id = Store.ensureIdentity("/lib/new.book.epub")
    Assert.eq(id.ref.source_id, "local")
    Assert.eq(id.ref.stable_id, "/lib/new.book.epub")
    Assert.is_nil(id.chapter_idx)
    Assert.eq(#book_upserts, 1)
    Assert.eq(book_upserts[1].source_id, "local")
    Assert.eq(book_upserts[1].stable_id, "/lib/new.book.epub")
    Assert.eq(book_upserts[1].md5, "digest-new")
    Assert.eq(book_upserts[1].title, "new.book") -- 文件名只去末尾扩展名
    Assert.eq(#open_upserts, 1)
    Assert.eq(open_upserts[1].source_id, "local")
    Assert.eq(open_upserts[1].stable_id, "/lib/new.book.epub")
    Assert.eq(open_upserts[1].path, "/lib/new.book.epub")
    lfs_modes["/lib/new.book.epub"] = nil
    md5_by_path["/lib/new.book.epub"] = nil
    book_upserts = {}
    open_upserts = {}
end

-- ── ensureIdentity：缓存路径无伴生 → nil 且不写库 ────────
do
    work_paths["/cache/moon/book/noid/2.html"] = { dir = "/cache/moon/book/noid", file = "2.html" }
    lfs_modes["/cache/moon/book/noid/2.html"] = "file" -- 即使是真实文件也不登记
    Assert.is_nil(Store.ensureIdentity("/cache/moon/book/noid/2.html"))
    Assert.eq(#book_upserts, 0)
    Assert.eq(#open_upserts, 0)
    work_paths["/cache/moon/book/noid/2.html"] = nil
    lfs_modes["/cache/moon/book/noid/2.html"] = nil
end

-- ── ensureIdentity：.moon 外路径一律归 local，不依赖文件存在性 ──
do
    local id = Store.ensureIdentity("/lib/ghost.epub")
    Assert.eq(id.ref.source_id, "local")
    Assert.eq(id.ref.stable_id, "/lib/ghost.epub")
    Assert.eq(#book_upserts, 1)
    Assert.eq(#open_upserts, 1)
    book_upserts = {}
    open_upserts = {}
end

Paths.sanitizeSourceId = orig_sanitize
Paths.ensureBookWork = orig_ensure
Paths.bookWorkDir = orig_work
Paths.splitBookWorkPath = orig_split
for _, k in ipairs({
    "utils.db.base",
    "utils.db.book",
    "utils.db.open",
    "utils.db.queue",
    "book.store",
    "libs/libkoreader-lfs",
    "ffi/util",
}) do
    package.preload[k] = nil
    package.loaded[k] = nil
end
