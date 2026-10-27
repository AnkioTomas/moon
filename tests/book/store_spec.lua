--[[--
book.store 路径精确查库身份解析离线用例

唯一规则：章节文件查 chapters 表 → 整本书查 books.path；
未中时 .moon 内拒开、.moon 外 touch 身份行（deleted=1，不上架）。

@module tests.book.store_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")

-- stub db / paths / ffi 最小集（数据驱动：各用例块自行填表）
local moon_paths = {} -- path → true（.moon 内）
package.loaded["reader.session.derived_note"] = { originOf = function() end }
package.preload["utils.paths"] = function()
    return {
        isMoonPath = function(path)
            return moon_paths[path] == true
        end,
        bookWorkDir = function(stable_id, source_id)
            return "/cache/" .. source_id .. "/" .. stable_id
        end,
        coverPath = function(stable_id, source_id)
            return "/cache/" .. source_id .. "/" .. stable_id .. ".jpg"
        end,
        cacheDir = function()
            return "/cache"
        end,
    }
end

local cached_images = {} -- url → 本地网络图缓存路径
package.preload["ui.themes.widgets.image.download"] = function()
    return {
        cached = function(url)
            return url and cached_images[url] or nil
        end,
    }
end

local warnings = {}
package.preload["utils.log"] = function()
    return {
        warn = function(...)
            warnings[#warnings + 1] = { ... }
        end,
        dbg = function() end,
        info = function() end,
    }
end

local purge_ok = true
local fake_dirs = {} -- path → {name=true}；lfs.dir 用，缺省空目录
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(_, field)
            if field == "mode" then return "directory" end
            return nil
        end,
        mkdir = function() return true end,
        dir = function(path)
            local list, entries = {}, fake_dirs[path]
            if entries then
                for name in pairs(entries) do list[#list + 1] = name end
                table.sort(list)
            end
            local i = 0
            return function()
                i = i + 1
                return list[i]
            end
        end,
    }
end
package.preload["ffi/util"] = function()
    return {
        purgeDir = function() return purge_ok end,
    }
end

local db_sql = {}
package.preload["utils.db"] = function()
    return {
        ensure = function() return true end,
        exec = function(sql)
            db_sql[#db_sql + 1] = sql
            return true
        end,
        transaction = function(fn)
            db_sql[#db_sql + 1] = "BEGIN IMMEDIATE;"
            local result = fn()
            db_sql[#db_sql + 1] = result and "COMMIT;" or "ROLLBACK;"
            return result
        end,
    }
end

local chapter_rows = {} -- path → chapters 行
local chapter_upserts = {}
local chapter_upsert_ok = true
local downloaded, downloaded_asks = {}, {}
package.preload["book.chapters_db"] = function()
    return {
        get = function(path)
            return chapter_rows[path]
        end,
        upsert = function(row)
            chapter_upserts[#chapter_upserts + 1] = row
            return chapter_upsert_ok
        end,
        deleteUnder = function() return true end,
        has = function(source_id, stable_id)
            downloaded_asks[#downloaded_asks + 1] = { source_id, stable_id, true }
            return downloaded[source_id .. "\0" .. stable_id] == true
        end,
    }
end

local toc_upserts = {}

local book_rows_by_path = {} -- path → books 行
local book_rows_by_id = {} -- "sid\0stid" → books 行
local book_upserts = {}
local book_upsert_ok = true
local book_batch_calls = 0
local touch_calls = {} -- { source_id, stable_id, path, chapter_idx }
local touch_ok = true
local mark_deleted_ok = true
package.preload["book.books_db"] = function()
    return {
        getByPath = function(path)
            return book_rows_by_path[path]
        end,
        get = function(source_id, stable_id)
            return book_rows_by_id[source_id .. "\0" .. tostring(stable_id)]
        end,
        upsert = function(row)
            book_upserts[#book_upserts + 1] = row
            return book_upsert_ok
        end,
        markDeleted = function()
            return mark_deleted_ok
        end,
        upsertRemote = function(row)
            book_upserts[#book_upserts + 1] = row
            return true
        end,
        upsertRemoteMany = function(rows)
            book_batch_calls = book_batch_calls + 1
            for _, row in ipairs(rows) do book_upserts[#book_upserts + 1] = row end
            return true
        end,
        isDownloaded = function(source_id, stable_id, chapter)
            downloaded_asks[#downloaded_asks + 1] = { source_id, stable_id, chapter }
            return downloaded[source_id .. "\0" .. stable_id] == true
        end,
        setToc = function(source_id, stable_id, payload)
            toc_upserts[#toc_upserts + 1] = {
                source_id = source_id, stable_id = stable_id, payload = payload,
            }
            return true
        end,
        libraryStableIdsBySource = function() return {} end,
        touchPath = function(source_id, stable_id, path)
            touch_calls[#touch_calls + 1] = {
                source_id = source_id,
                stable_id = stable_id,
                path = path,
            }
            return touch_ok
        end,
    }
end


-- partialMD5 由用例按路径填表控制（真实实现打不开文件返回 nil，不抛错）
local md5_by_path = {}
-- partialMD5 在 frontend/util.lua（不是 ffi/util）；store 按真实归属 require("util")
package.loaded["util"] = nil
package.preload["util"] = function()
    return {
        partialMD5 = function(path)
            return md5_by_path[path]
        end,
    }
end

-- 属主源解析由用例控制：current 命中直接用，否则 create 建实例
local registry_current = nil
local registry_created = {}
package.preload["source.registry"] = function()
    return {
        current = function()
            return registry_current
        end,
        create = function(id)
            registry_created[#registry_created + 1] = id
            return { id = id }
        end,
        resolve = function(id)
            if registry_current and registry_current.id == id then
                return registry_current
            end
            registry_created[#registry_created + 1] = id
            return { id = id }
        end,
        meta = function(id)
            if id == "wechat" or id == "jdread" or id == "copymanga" then
                return { id = id, type = "chapter" }
            end
            if type(id) == "string" and id ~= "" then
                return { id = id, type = "book" }
            end
            return nil
        end,
    }
end

local Store = require("book.store")

-- ── isCached：章节源缓存过任意一章即算（ChapterDB.has，不要求从当前章起连续）；整本源 path 须在 cache 内（本地原书恒 false）──
do
    downloaded["wechat\0cached-book"] = true
    Assert.is_true(Store.isCached({ source_id = "wechat", stable_id = "cached-book" }))
    local ask = downloaded_asks[#downloaded_asks]
    Assert.eq(ask[1], "wechat")
    Assert.eq(ask[2], "cached-book")
    Assert.is_true(ask[3])
    downloaded["wechat\0cached-book"] = nil
    Assert.is_false(Store.isCached({ source_id = "wechat", stable_id = "cached-book" }))

    local asks = #downloaded_asks
    Assert.is_true(Store.isCached({ source_id = "moon", path = "/cache/moon/book/x/a.epub" }))
    Assert.is_true(Store.isCached({ source_id = "local", path = "/cache/local/book/webdav/a.epub" }))
    Assert.is_false(Store.isCached({ source_id = "local", path = "/books/a.epub" }))
    Assert.is_false(Store.isCached({ source_id = "local", path = "/cache2/a.epub" }))
    Assert.is_false(Store.isCached({ source_id = "moon" }))
    Assert.eq(#downloaded_asks, asks, "整本源不查库")
end

-- ── identityFor：chapters 命中 → 章节身份（优先于 books.path）──
do
    local path = "/cache/moon/book/slug/3.html"
    chapter_rows[path] = { source_id = "moon", stable_id = "s1", chapter_idx = 3 }
    -- 同时伪造 books.path 命中：chapters 必须赢
    book_rows_by_path[path] = { source_id = "other", stable_id = "sX" }
    book_rows_by_id["moon\0s1"] = { source_id = "moon", stable_id = "s1", title = "章书元数据" }
    local id = Store.identityFor(path)
    Assert.eq(id.source_id, "moon")
    Assert.eq(id.stable_id, "s1")
    Assert.eq(id.chapter_idx, 3)
    Assert.eq(id.book.title, "章书元数据")
    chapter_rows[path] = nil
    book_rows_by_path[path] = nil
    book_rows_by_id["moon\0s1"] = nil
end

-- ── identityFor：books.path 命中 → 整本书身份（chapter_idx=nil）──
do
    book_rows_by_path["/lib/a.epub"] = { source_id = "moon", stable_id = "s2", title = "整本书" }
    local id = Store.identityFor("/lib/a.epub")
    Assert.eq(id.source_id, "moon")
    Assert.eq(id.stable_id, "s2")
    Assert.is_nil(id.chapter_idx)
    Assert.eq(id.book.title, "整本书")
    book_rows_by_path["/lib/a.epub"] = nil
end

-- ── identityFor：两表都未中 → nil ────────────────────────
do
    Assert.is_nil(Store.identityFor("/nowhere/gone.epub"))
end

-- ── ensureIdentity：命中章节身份 → 只刷新 books.path，chapters 已在库不重写 ──
do
    local path = "/cache/moon/book/slug/5.html"
    chapter_rows[path] = { source_id = "moon", stable_id = "sk", chapter_idx = 5 }
    local id = Store.ensureIdentity(path)
    Assert.eq(id.source_id, "moon")
    Assert.eq(id.stable_id, "sk")
    Assert.eq(id.chapter_idx, 5)
    Assert.eq(#touch_calls, 1)
    Assert.eq(touch_calls[1].source_id, "moon")
    Assert.eq(touch_calls[1].stable_id, "sk")
    Assert.eq(touch_calls[1].path, path)
    Assert.eq(#chapter_upserts, 0)
    Assert.eq(#book_upserts, 0) -- 命中身份不写 books 元数据
    Assert.eq(id.source.id, "moon") -- ensureIdentity 附属主源
    Assert.is_false(id.ephemeral)
    chapter_rows[path] = nil
    touch_calls = {}
    chapter_upserts = {}
    registry_created = {}
end

-- ── ensureIdentity：命中整本书身份 → 只 touch books，不写 chapters ──
-- current 即属主源：直接用 current，不另建实例
do
    book_rows_by_path["/lib/known.epub"] = { source_id = "moon", stable_id = "s3" }
    registry_current = { id = "moon" }
    local id = Store.ensureIdentity("/lib/known.epub")
    Assert.eq(id.stable_id, "s3")
    Assert.is_nil(id.chapter_idx)
    Assert.eq(id.source, registry_current)
    Assert.eq(#registry_created, 0)
    Assert.eq(#touch_calls, 1)
    Assert.eq(touch_calls[1].stable_id, "s3")
    Assert.is_nil(touch_calls[1].chapter_idx)
    Assert.eq(#chapter_upserts, 0)
    book_rows_by_path["/lib/known.epub"] = nil
    touch_calls = {}
end

-- ── ensureIdentity：current 不是属主源 → 按身份 source_id 建实例 ──
do
    book_rows_by_path["/lib/old.epub"] = { source_id = "moon", stable_id = "s4" }
    registry_current = { id = "wechat" } -- current 是别的源：不许拿它操作 moon 的书
    local id = Store.ensureIdentity("/lib/old.epub")
    Assert.eq(registry_created[#registry_created], "moon")
    Assert.eq(id.source.id, "moon")
    registry_current = nil
    registry_created = {}
    book_rows_by_path["/lib/old.epub"] = nil
    touch_calls = {}
end

-- ── identityFor：纯读路径，不解析源（registry 零调用）──
do
    book_rows_by_path["/lib/ro.epub"] = { source_id = "moon", stable_id = "s5" }
    local id = Store.identityFor("/lib/ro.epub")
    Assert.eq(id.stable_id, "s5")
    Assert.is_nil(id.source)
    Assert.eq(#registry_created, 0)
    book_rows_by_path["/lib/ro.epub"] = nil
end

-- ── ensureIdentity：.moon 内未知文件 → nil 且不写库 ──────
do
    moon_paths["/data/.moon/cache/moon/book/noid/2.html"] = true
    Assert.is_nil(Store.ensureIdentity("/data/.moon/cache/moon/book/noid/2.html"))
    Assert.eq(#book_upserts, 0)
    Assert.eq(#touch_calls, 0)
    Assert.eq(#chapter_upserts, 0)
    moon_paths["/data/.moon/cache/moon/book/noid/2.html"] = nil
end

-- ── ensureIdentity：.moon 外未入库 → touch 身份行（deleted=1 不上架），不 upsert ──
do
    md5_by_path["/lib/new.book.epub"] = "digest-new"
    local id = Store.ensureIdentity("/lib/new.book.epub")
    Assert.eq(id.source_id, "local")
    Assert.eq(id.stable_id, "/lib/new.book.epub")
    Assert.is_nil(id.chapter_idx)
    Assert.eq(id.book.title, "new.book")
    Assert.eq(id.book.path, "/lib/new.book.epub")
    Assert.eq(tonumber(id.book.deleted), 1, "库外顺手登记不上架")
    Assert.eq(#book_upserts, 0, "禁止 upsert 上架")
    Assert.eq(#touch_calls, 1)
    Assert.eq(touch_calls[1].source_id, "local")
    Assert.eq(touch_calls[1].stable_id, "/lib/new.book.epub")
    Assert.eq(touch_calls[1].path, "/lib/new.book.epub")
    Assert.eq(registry_created[#registry_created], "local")
    Assert.eq(id.source.id, "local")
    md5_by_path["/lib/new.book.epub"] = nil
    touch_calls = {}
    registry_created = {}
end

-- ── ensureIdentity：local 已登记 → 不覆盖元数据，只补 path ──
do
    book_rows_by_id["local\0/lib/scanned.epub"] = {
        source_id = "local",
        stable_id = "/lib/scanned.epub",
        title = "扫盘解析的标题",
        deleted = 0,
    }
    local id = Store.ensureIdentity("/lib/scanned.epub")
    Assert.eq(id.source_id, "local")
    Assert.eq(id.stable_id, "/lib/scanned.epub")
    Assert.eq(id.book.title, "扫盘解析的标题")
    Assert.eq(#book_upserts, 0)
    Assert.eq(#touch_calls, 1)
    Assert.eq(touch_calls[1].path, "/lib/scanned.epub")
    book_rows_by_id["local\0/lib/scanned.epub"] = nil
    touch_calls = {}
end

-- ── ensureIdentity：衍生版文件 → 按 meta 解析回原书身份，不改 books.path ──
do
    package.loaded["reader.session.derived_note"] = {
        originOf = function(file) return file == "/w/reflow/book.epub" and "/lib/a.epub" or nil end,
    }
    book_rows_by_path["/lib/a.epub"] = { source_id = "moon", stable_id = "s2", title = "整本书" }
    local id = Store.ensureIdentity("/w/reflow/book.epub")
    Assert.eq(id.source_id, "moon")
    Assert.eq(id.stable_id, "s2")
    Assert.eq(#touch_calls, 0)
    package.loaded["reader.session.derived_note"] = { originOf = function() end }
    book_rows_by_path["/lib/a.epub"] = nil
end

-- ── ensureIdentity：文件打不开 → partialMD5 返回 nil，仍 touch 身份 ────
do
    local id = Store.ensureIdentity("/lib/broken.epub")
    Assert.eq(id.source_id, "local")
    Assert.eq(id.book.title, "broken")
    Assert.eq(#book_upserts, 0)
    Assert.eq(#touch_calls, 1)
    touch_calls = {}
end

-- ── ensureIdentity：touch 失败仍返回身份，并记 warn ──
do
    warnings = {}
    touch_ok = false
    local id = Store.ensureIdentity("/lib/fail-register.epub")
    Assert.eq(id.source_id, "local")
    Assert.eq(id.stable_id, "/lib/fail-register.epub")
    Assert.eq(warnings[1][1], "book identity touch failed")
    touch_ok = true
    touch_calls = {}
    warnings = {}
end

-- ── markDeleted：标删成功、目录 purge 失败仍返回 true ──
do
    warnings = {}
    purge_ok = false
    local ok, leftover = Store.markDeleted("wechat", "gone")
    Assert.is_true(ok)
    Assert.eq(leftover, "partial")
    Assert.eq(warnings[1][1], "book cache purge failed")
    purge_ok = true
    warnings = {}
end

-- ── markDeleted：工作目录改名移进 .trash 后交给后台分 tick 删，不同步 purge ──
do
    local purged = {}
    package.loaded["book.cache"] = { purgeAsync = function(dir) purged[#purged + 1] = dir end }
    local original_rename = os.rename
    local renamed
    os.rename = function(from, to) renamed = { from, to }; return true end
    purge_ok = false
    local ok, leftover = Store.markDeleted("wechat", "moved")
    os.rename = original_rename
    purge_ok = true
    package.loaded["book.cache"] = nil
    Assert.is_true(ok)
    Assert.is_nil(leftover, "改名成功即算删掉")
    Assert.matches(renamed[2], "/%.trash/%d+%-%d+$")
    Assert.eq(purged[1], renamed[2])
    warnings = {}
end

-- ── clearCache：删工作目录/封面/封面网络图；cache 内 path 清空，cache 外原书不动 ──
do
    local removed = {}
    local original_remove = os.remove
    os.remove = function(path)
        removed[#removed + 1] = path
        return true
    end
    cached_images["https://img.test/c.jpg"] = "/cache/image/abc.jpg"
    book_rows_by_id["local\0dav/a.epub"] = {
        source_id = "local", stable_id = "dav/a.epub",
        path = "/cache/local/book/webdav/a.epub", cover = "https://img.test/c.jpg",
    }
    local ok, leftover = Store.clearCache("local", "dav/a.epub")
    Assert.is_true(ok)
    Assert.is_nil(leftover)
    Assert.contains(removed, "/cache/local/dav/a.epub.jpg")
    Assert.contains(removed, "/cache/image/abc.jpg")
    Assert.contains(removed, "/cache/local/book/webdav/a.epub")
    Assert.eq(#touch_calls, 1)
    Assert.is_nil(touch_calls[1].path)

    -- 软删除：文档照删，封面文件与封面网络图留着
    removed = {}
    touch_calls = {}
    Assert.is_true(Store.clearCache("local", "dav/a.epub", true))
    Assert.contains(removed, "/cache/local/book/webdav/a.epub")
    for _, p in ipairs(removed) do
        Assert.is_true(p ~= "/cache/local/dav/a.epub.jpg" and p ~= "/cache/image/abc.jpg")
    end

    removed = {}
    touch_calls = {}
    book_rows_by_id["local\0/lib/x.epub"] = {
        source_id = "local", stable_id = "/lib/x.epub", path = "/lib/x.epub",
    }
    Assert.is_true(Store.clearCache("local", "/lib/x.epub"))
    Assert.eq(#touch_calls, 0)
    for _, p in ipairs(removed) do Assert.is_true(p ~= "/lib/x.epub") end

    -- 前缀相似但不在 cache 目录内的路径不算缓存
    book_rows_by_id["local\0/cache2/y.epub"] = {
        source_id = "local", stable_id = "/cache2/y.epub", path = "/cache2/y.epub",
    }
    Assert.is_true(Store.clearCache("local", "/cache2/y.epub"))
    Assert.eq(#touch_calls, 0)

    touch_ok = false
    Assert.is_false(Store.clearCache("local", "dav/a.epub"))
    touch_ok = true

    os.remove = original_remove
    cached_images = {}
    book_rows_by_id["local\0dav/a.epub"] = nil
    book_rows_by_id["local\0/lib/x.epub"] = nil
    book_rows_by_id["local\0/cache2/y.epub"] = nil
    touch_calls = {}
end

-- ── clearCache：把 KOReader 的 .sdr 边车搬回工作目录，正文照删 ──
do
    local renames = {}
    local original_rename = os.rename
    local original_remove = os.remove
    os.rename = function(from, to)
        renames[#renames + 1] = { from, to }
        return true
    end
    os.remove = function() return true end
    package.loaded["book.cache"] = { purgeAsync = function() end }

    fake_dirs["/cache/local/dav/keep"] = {
        ["book.epub"] = true, ["book.sdr"] = true, ["page.jpg"] = true,
    }
    book_rows_by_id["local\0dav/keep"] = {
        source_id = "local", stable_id = "dav/keep",
        path = "/cache/local/book/dav/keep/book.epub",
    }
    Assert.is_true(Store.clearCache("local", "dav/keep"))

    os.rename = original_rename
    os.remove = original_remove
    package.loaded["book.cache"] = nil
    fake_dirs = {}
    book_rows_by_id["local\0dav/keep"] = nil
    touch_calls = {}
    -- 工作目录先整体改名进 .trash，边车再单独搬回原位
    Assert.eq(renames[1][1], "/cache/local/dav/keep")
    Assert.matches(renames[1][2], "/%.trash/")
    local restored
    for _idx, r in ipairs(renames) do
        if r[1]:match("book%.sdr$") and r[2] == "/cache/local/dav/keep/book.sdr" then
            restored = true
        end
    end
    Assert.is_true(restored, "边车必须搬回书的工作目录")
end

-- ── touch：章节详情和路径在同一事务登记；目录不经这里 ──
do
    local identity = { source_id = "moon", stable_id = "s9" }
    Assert.is_true(Store.touch("/cache/moon/book/slug/7.html", identity, {
        chapter_idx = 7,
        book = { title = "最新详情" },
    }))
    Assert.eq(#touch_calls, 1)
    Assert.eq(touch_calls[1].source_id, "moon")
    Assert.eq(touch_calls[1].stable_id, "s9")
    Assert.eq(touch_calls[1].path, "/cache/moon/book/slug/7.html")
    Assert.eq(#chapter_upserts, 1)
    Assert.eq(chapter_upserts[1].path, "/cache/moon/book/slug/7.html")
    Assert.eq(chapter_upserts[1].chapter_idx, 7)
    Assert.len(toc_upserts, 0)
    Assert.eq(book_upserts[#book_upserts].source_id, "moon")
    Assert.eq(book_upserts[#book_upserts].stable_id, "s9")
    Assert.eq(book_upserts[#book_upserts].title, "最新详情")
    Assert.eq(db_sql[1], "BEGIN IMMEDIATE;")
    Assert.eq(db_sql[#db_sql], "COMMIT;")
    touch_calls = {}
    chapter_upserts = {}
    toc_upserts = {}
    book_upserts = {}
    db_sql = {}
end

-- ── touch：任一登记失败返回 false + 原因 ────────────────
do
    local identity = { source_id = "moon", stable_id = "broken" }
    chapter_upsert_ok = false
    local ok, err = Store.touch("/cache/moon/book/slug/8.html", identity, { chapter_idx = 8 })
    Assert.is_false(ok)
    Assert.matches(err, "failed to register chapter path")
    Assert.eq(db_sql[#db_sql], "ROLLBACK;")
    chapter_upsert_ok = true
    touch_calls = {}
    chapter_upserts = {}
    db_sql = {}

    touch_ok = false
    ok, err = Store.touch("/lib/broken.epub", identity)
    Assert.is_false(ok)
    Assert.matches(err, "failed to register book path")
    touch_ok = true
    touch_calls = {}
end

-- ── touch：不带 chapter_idx（opts=nil / opts={}）→ 只登记 books ──
do
    local identity = { source_id = "moon", stable_id = "s10" }
    Store.touch("/lib/whole.epub", identity, nil)
    Store.touch("/lib/whole2.epub", identity, {})
    Assert.eq(#touch_calls, 2)
    Assert.eq(touch_calls[1].path, "/lib/whole.epub")
    Assert.is_nil(touch_calls[1].chapter_idx)
    Assert.eq(touch_calls[2].path, "/lib/whole2.epub")
    Assert.is_nil(touch_calls[2].chapter_idx)
    Assert.eq(#chapter_upserts, 0)
    touch_calls = {}
end

-- ── rememberMany：有身份列逐条 upsert，无身份条目跳过 ────────
do
    Store.rememberMany({
        {
            source_id = "moon",
            stable_id = "a.epub",
            md5 = "m1",
            title = "标题",
            authors = "作者",
            percent = 12,
            category = "分类",
            series = "系列",
            intro = "简介",
            cover = "https://img.test/a.jpg",
            meta = { publisher = "出版社", words = 1000 },
            path = "/should/not/persist.epub", -- rememberMany 不写 path
        },
        { title = "无身份临时条目" },
    })
    Assert.eq(#book_upserts, 1)
    Assert.eq(book_upserts[1].source_id, "moon")
    Assert.eq(book_upserts[1].stable_id, "a.epub")
    Assert.eq(book_upserts[1].md5, "m1")
    Assert.eq(book_upserts[1].title, "标题")
    Assert.eq(book_upserts[1].authors, "作者")
    Assert.eq(book_upserts[1].category, "分类")
    Assert.eq(book_upserts[1].series, "系列")
    Assert.eq(book_upserts[1].intro, "简介")
    Assert.eq(book_upserts[1].cover, "https://img.test/a.jpg")
    Assert.eq(book_upserts[1].meta.publisher, "出版社", "扩展元数据随书架快照落库")
    Assert.eq(book_upserts[1].meta.words, 1000)
    Assert.is_nil(book_upserts[1].percent)
    Assert.is_nil(book_upserts[1].inserted_at)
    Assert.is_nil(book_upserts[1].path) -- path 由 touchPath 单独维护
    Assert.eq(book_batch_calls, 1)
    book_upserts = {}
    book_batch_calls = 0
end

-- ── rememberMany：全部无身份 → 一条都不写 ────────────────
do
    Store.rememberMany({ { title = "x" }, { title = "y" } })
    Store.rememberMany({})
    Assert.eq(#book_upserts, 0)
    Assert.eq(book_batch_calls, 0)
end

for _, k in ipairs({
    "utils.paths",
    "utils.db",
    "book.books_db",
    "book.chapters_db",

    "source.registry",
    "ui.themes.widgets.image.download",
    "book.store",
    "util",
}) do
    package.preload[k] = nil
    package.loaded[k] = nil
end
