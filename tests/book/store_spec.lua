--[[--
book.store 路径精确查库身份解析离线用例

唯一规则：章节文件查 chapters 表 → 整本书查 books.path；
未中时 .moon 内拒开、.moon 外登记 local 书。

@module tests.book.store_spec
--]]

local Assert = require("support.assert")

-- stub db / paths / ffi 最小集（数据驱动：各用例块自行填表）
local moon_paths = {} -- path → true（.moon 内）
package.preload["utils.paths"] = function()
    return {
        isMoonPath = function(path)
            return moon_paths[path] == true
        end,
    }
end

local db_sql = {}
package.preload["db.base"] = function()
    return {
        ensure = function() return true end,
        exec = function(sql)
            db_sql[#db_sql + 1] = sql
            return true
        end,
    }
end

local chapter_rows = {} -- path → chapters 行
local chapter_upserts = {}
local chapter_upsert_ok = true
local chapter_counts = {}
package.preload["db.chapter"] = function()
    return {
        get = function(path)
            return chapter_rows[path]
        end,
        upsert = function(row)
            chapter_upserts[#chapter_upserts + 1] = row
            return chapter_upsert_ok
        end,
        countByBook = function(source_id, stable_id)
            return chapter_counts[source_id .. "\0" .. stable_id] or 0
        end,
    }
end

local toc_rows = {}
local toc_upserts = {}

local json_values = {}
package.preload["json"] = function()
    return {
        encode = function(value)
            local payload = "toc:" .. tostring(#toc_upserts + 1)
            json_values[payload] = value
            return payload
        end,
        decode = function(payload) return json_values[payload] end,
    }
end

local book_rows_by_path = {} -- path → books 行
local book_rows_by_id = {} -- "sid\0stid" → books 行
local book_upserts = {}
local book_batch_calls = 0
local touch_calls = {} -- { source_id, stable_id, path, chapter_idx }
local touch_ok = true
package.preload["db.book"] = function()
    return {
        getByPath = function(path)
            return book_rows_by_path[path]
        end,
        get = function(source_id, stable_id)
            return book_rows_by_id[source_id .. "\0" .. tostring(stable_id)]
        end,
        upsert = function(row)
            book_upserts[#book_upserts + 1] = row
            return true
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
        getToc = function(source_id, stable_id)
            return toc_rows[source_id .. "\0" .. stable_id]
        end,
        setToc = function(source_id, stable_id, payload)
            toc_upserts[#toc_upserts + 1] = {
                source_id = source_id, stable_id = stable_id, payload = payload,
            }
            toc_rows[source_id .. "\0" .. stable_id] = payload
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
    }
end

local Store = require("book.store")

-- ── allChaptersCached：目录数量与本地章节登记数必须一致 ──
do
    local identity = { source_id = "wechat", stable_id = "cached-book" }
    toc_rows["wechat\0cached-book"] = "toc:cached"
    json_values["toc:cached"] = { { idx = 1 }, { idx = 2 } }
    chapter_counts["wechat\0cached-book"] = 2
    Assert.is_true(Store.allChaptersCached(identity))
    chapter_counts["wechat\0cached-book"] = 1
    Assert.is_false(Store.allChaptersCached(identity))
    Assert.is_false(Store.allChaptersCached({ source_id = "wechat", stable_id = "no-toc" }))
    toc_rows["wechat\0cached-book"] = nil
    chapter_counts["wechat\0cached-book"] = nil
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

-- isCurrentDocument：同一书籍且同一章节才允许异步回调继续
do
    local path = "/lib/current.epub"
    book_rows_by_path[path] = { source_id = "moon", stable_id = "current" }
    local ui = { document = { file = path } }
    Assert.is_true(Store.isCurrentDocument(ui, {
        source_id = "moon", stable_id = "current", chapter_idx = nil,
    }))
    Assert.is_false(Store.isCurrentDocument(ui, {
        source_id = "wechat", stable_id = "current", chapter_idx = nil,
    }))
    book_rows_by_path[path] = nil
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

-- ── ensureIdentity：.moon 外未入库 → 当 local 源书登记 ────
do
    md5_by_path["/lib/new.book.epub"] = "digest-new"
    local id = Store.ensureIdentity("/lib/new.book.epub")
    Assert.eq(id.source_id, "local")
    Assert.eq(id.stable_id, "/lib/new.book.epub")
    Assert.is_nil(id.chapter_idx)
    Assert.eq(id.book.title, "new.book")
    Assert.eq(id.book.path, "/lib/new.book.epub")
    Assert.eq(#book_upserts, 1)
    Assert.eq(book_upserts[1].source_id, "local")
    Assert.eq(book_upserts[1].stable_id, "/lib/new.book.epub")
    Assert.eq(book_upserts[1].md5, "digest-new")
    Assert.eq(book_upserts[1].title, "new.book") -- 文件名只去末尾扩展名
    Assert.eq(book_upserts[1].path, "/lib/new.book.epub")
    Assert.is_true(type(book_upserts[1].fetched_at) == "number")
    Assert.eq(#touch_calls, 1)
    Assert.eq(touch_calls[1].source_id, "local")
    Assert.eq(touch_calls[1].stable_id, "/lib/new.book.epub")
    Assert.eq(touch_calls[1].path, "/lib/new.book.epub")
    Assert.is_nil(touch_calls[1].chapter_idx)
    Assert.eq(registry_created[#registry_created], "local")
    Assert.eq(id.source.id, "local")
    md5_by_path["/lib/new.book.epub"] = nil
    book_upserts = {}
    touch_calls = {}
    registry_created = {}
end

-- ── ensureIdentity：local 已登记 → 不覆盖元数据，只补 path ──
do
    book_rows_by_id["local\0/lib/scanned.epub"] = {
        source_id = "local",
        stable_id = "/lib/scanned.epub",
        title = "扫盘解析的标题",
    }
    local id = Store.ensureIdentity("/lib/scanned.epub")
    Assert.eq(id.source_id, "local")
    Assert.eq(id.stable_id, "/lib/scanned.epub")
    Assert.eq(#book_upserts, 0) -- 已有行不 upsert，元数据不被覆盖
    Assert.eq(#touch_calls, 1) -- 但仍无条件补 path
    Assert.eq(touch_calls[1].path, "/lib/scanned.epub")
    book_rows_by_id["local\0/lib/scanned.epub"] = nil
    touch_calls = {}
end

-- ── ensureIdentity：文件打不开 → partialMD5 返回 nil，md5=nil 仍登记 ────
do
    local id = Store.ensureIdentity("/lib/broken.epub")
    Assert.eq(id.source_id, "local")
    Assert.eq(#book_upserts, 1)
    Assert.is_nil(book_upserts[1].md5)
    Assert.eq(book_upserts[1].title, "broken")
    Assert.eq(#touch_calls, 1)
    book_upserts = {}
    touch_calls = {}
end

-- ── touch：章节详情、目录和路径在同一事务登记 ──
do
    local identity = { source_id = "moon", stable_id = "s9" }
    local toc = { { idx = 1, title = "一" }, { idx = 2, title = "二" } }
    Assert.is_true(Store.touch("/cache/moon/book/slug/7.html", identity, {
        chapter_idx = 7,
        toc = toc,
        book = { title = "最新详情" },
    }))
    Assert.eq(#touch_calls, 1)
    Assert.eq(touch_calls[1].source_id, "moon")
    Assert.eq(touch_calls[1].stable_id, "s9")
    Assert.eq(touch_calls[1].path, "/cache/moon/book/slug/7.html")
    Assert.eq(#chapter_upserts, 1)
    Assert.eq(chapter_upserts[1].path, "/cache/moon/book/slug/7.html")
    Assert.eq(chapter_upserts[1].chapter_idx, 7)
    Assert.eq(toc_upserts[1].source_id, "moon")
    Assert.eq(toc_upserts[1].stable_id, "s9")
    Assert.eq(Store.toc(identity), toc)
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
    Assert.eq(book_upserts[1].percent, 12)
    Assert.eq(book_upserts[1].category, "分类")
    Assert.eq(book_upserts[1].series, "系列")
    Assert.eq(book_upserts[1].intro, "简介")
    Assert.eq(book_upserts[1].cover, "https://img.test/a.jpg")
    Assert.is_true(type(book_upserts[1].fetched_at) == "number")
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
    "db.base",
    "db.book",
    "db.chapter",

    "source.registry",
    "book.store",
    "util",
}) do
    package.preload[k] = nil
    package.loaded[k] = nil
end
