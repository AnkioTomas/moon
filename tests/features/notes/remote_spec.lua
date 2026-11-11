--[[--
features.notes：跨书列表分页/筛选/搜索、隐藏墓碑与空书签、导出 Markdown、HTTP 接口。

@module tests.features.notes.remote_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")
local Config = require("support.config")

local JSON = require("support.json_stub")
package.loaded["json"] = JSON
package.preload["json"] = function() return JSON end

local sqlite_ok = pcall(require, "lua-ljsqlite3/init")
if not sqlite_ok then
    Assert.skip("当前离线环境没有 ljsqlite3 Lua 模块")
end

local dir = Config.dir() .. "/notes_remote_spec"
local lfs = require("libs/libkoreader-lfs")
lfs.mkdir(dir)
lfs.mkdir(dir .. "/cache")
lfs.mkdir(dir .. "/cache/tmp")
local db_path = dir .. "/book.sqlite3"
for _idx, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(db_path .. suffix) end

local tmp_seq = 0
package.loaded["utils.paths"] = nil
package.preload["utils.paths"] = function()
    return {
        dbPath = function() return db_path end,
        ensureSettings = function() end,
        root = function() return dir end,
        cacheDir = function() return dir .. "/cache" end,
        tmpDir = function() return dir .. "/cache/tmp" end,
        ensureDir = function() return true end,
        tmpname = function(suffix)
            tmp_seq = tmp_seq + 1
            return dir .. "/cache/tmp/export-" .. tmp_seq .. (suffix or "")
        end,
    }
end
package.loaded["ui/network/manager"] = { isConnected = function() return false end }
package.loaded["source.registry"] = { resolve = function(id) return { id = id } end }
package.loaded["apps/reader/readerui"] = { instance = nil }
package.loaded["reader.session"] = { _snapshot = nil }

for _idx, name in ipairs({
    "utils.db", "book.books_db", "book.note_db", "book.note",
    "features.notes.query", "features.notes.remote",
}) do
    package.loaded[name] = nil
end

local Base = require("utils.db")
local BookDB = require("book.books_db")
local NoteDB = require("book.note_db")
local Note = require("book.note")
local Query = require("features.notes.query")
local Remote = require("features.notes.remote")
Assert.not_nil(Base.open())

Assert.is_true(BookDB.upsert({ source_id = "wechat", stable_id = "book-1", title = "活着", authors = "余华", deleted = 0 }))
Assert.is_true(BookDB.upsert({ source_id = "local", stable_id = "book-2", title = "地方志", authors = "", deleted = 0 }))

local function ann(opts)
    local it = {
        datetime = opts.datetime or "2026-11-01 10:00:00",
        color = "yellow",
        text = opts.text,
        note = opts.note,
        page = opts.page or "/body/p[1]/text()[1].0",
        pos0 = opts.pos0 or "/body/p[1]/text()[1].0",
        pos1 = opts.pos1 or "/body/p[1]/text()[1].3",
        chapter = opts.chapter or "第一章",
        wr_deleted = opts.wr_deleted,
        wr_bookmark_id = opts.wr_bookmark_id,
        kavita_deleted = opts.kavita_deleted,
    }
    if opts.drawer ~= false then
        it.drawer = opts.drawer or "lighten"
    end
    return it
end

local items1 = {}
for i = 1, 32 do
    items1[#items1 + 1] = ann({
        datetime = string.format("2026-11-01 %02d:00:00", i % 24),
        text = "活着句子" .. i,
        note = (i % 5 == 0) and ("想法" .. i) or nil,
        pos0 = "/body/p[1]/text()[1]." .. i,
        pos1 = "/body/p[1]/text()[1]." .. (i + 2),
    })
end
-- 墓碑与空书签不应出现在列表里。
items1[#items1 + 1] = ann({ text = "已删", wr_deleted = true, wr_bookmark_id = "gone" })
items1[#items1 + 1] = { datetime = "2026-11-01 00:00:00", page = "/body/p[1]/text()[1].0", text = "" }
items1[#items1 + 1] = ann({ text = "书签无划线", drawer = false, page = "/body/p[9]/text()[1].0" })

Assert.is_true(NoteDB.upsert("wechat", "book-1", 1, JSON.encode(items1), 200, true))
Assert.is_true(NoteDB.upsert("local", "book-2", 0, JSON.encode({
    ann({ datetime = "2026-11-02 08:00:00", text = "地方志摘录", note = "要查出处", chapter = "风俗" }),
}), 300))

-- 可列出：32 条活着 + 1 条地方志；墓碑、空文本、无 drawer 且我们定义为 bookmark 的有文本书签被跳过。
local all = Query.list({ page = 1 })
Assert.eq(all.total, 33)
Assert.eq(#all.items, Query.PAGE)
Assert.eq(all.pages, 2)
Assert.eq(all.items[1].text, "地方志摘录")
Assert.eq(all.items[1].title, "地方志")
Assert.eq(all.items[1].type, "note")
Assert.is_true(all.items[1].dirty)
Assert.eq(all.items[1].color, "yellow")
Assert.eq(all.items[1].drawer, "lighten")
-- 不把原始 pos 表或整份快照交出去。
Assert.is_nil(all.items[1].pos0)
Assert.is_nil(all.items[1].payload)
Assert.is_nil(all.items[1].wr_deleted)

local page2 = Query.list({ page = 2 })
Assert.eq(#page2.items, 3)
Assert.eq(page2.page, 2)

-- 按书、类型、搜索。
local only_local = Query.list({ source_id = "local", stable_id = "book-2" })
Assert.eq(only_local.total, 1)
local notes_only = Query.list({ type = "note" })
Assert.eq(notes_only.total, 1 + 6) -- 地方志 1 条 + 活着每 5 条一条想法（5,10,15,20,25,30）
local search = Query.list({ q = "想法5" })
Assert.eq(search.total, 1)
Assert.eq(search.items[1].note, "想法5")
local by_title = Query.list({ q = "活着" })
Assert.eq(by_title.total, 32)

-- 长中文摘录按 UTF-8 字符边界截断，不能把 JSON 弄成非法字节。
do
    local Text = require("utils.text")
    local long = string.rep("然而临到他走进屋来那苍白的脸", 20) .. "正文末尾词"
    local long_note = string.rep("这是很长的备注", 20) .. "备注末尾词"
    Assert.is_true(#long > Query.EXCERPT)
    Assert.is_true(NoteDB.upsert("local", "utf8-book", 0, JSON.encode({
        ann({ datetime = "2026-11-03 09:00:00", text = long, note = long_note, chapter = "长摘录" }),
    }), 400))
    Assert.is_true(BookDB.upsert({ source_id = "local", stable_id = "utf8-book", title = "UTF8截断", authors = "", deleted = 0 }))
    local row = Query.list({ source_id = "local", stable_id = "utf8-book" })
    Assert.eq(row.total, 1)
    local excerpt = row.items[1].text
    Assert.is_true(Text.isValidUtf8(excerpt))
    Assert.is_true(#excerpt > Query.EXCERPT) -- 正文截到上限后再加省略号
    Assert.is_true(excerpt:find("…", 1, true) ~= nil)
    for _idx, q in ipairs({ "正文末尾词", "备注末尾词" }) do
        local matched = Query.list({ q = q })
        Assert.eq(matched.total, 1)
        Assert.is_nil(matched.items[1].text:find("正文末尾词", 1, true))
        Assert.is_nil(matched.items[1].note:find("备注末尾词", 1, true))
        Assert.eq(Query.books({ q = q }).total, 1)
    end
    -- 清空快照，避免后面的全局 books/export/HTTP 计数被这条打乱。
    Assert.is_true(NoteDB.upsert("local", "utf8-book", 0, "[]", 400))
end

-- 墓碑 / 空书签不会被搜到。
Assert.eq(Query.list({ q = "已删" }).total, 0)
Assert.eq(Query.list({ q = "书签无划线" }).total, 0)

local books = Query.books()
Assert.eq(books.total, 2)
Assert.eq(books.pages, 1)
Assert.eq(books.page, 1)
Assert.eq(#books.books, 2)
Assert.eq(books.books[1].title, "地方志") -- 按书名排
Assert.eq(books.books[2].title, "活着")
Assert.eq(books.books[2].count, 32)

-- 书籍列表也按 q / type 过滤，并分页。
local by_title_books = Query.books({ q = "活着" })
Assert.eq(by_title_books.total, 1)
Assert.eq(by_title_books.books[1].title, "活着")
Assert.eq(by_title_books.books[1].count, 32)
local note_books = Query.books({ type = "note" })
Assert.eq(note_books.total, 2)
Assert.eq(Query.books({ q = "想法5" }).total, 1)
for i = 1, 31 do
    local sid = string.format("page-book-%02d", i)
    Assert.is_true(BookDB.upsert({ source_id = "local", stable_id = sid, title = "分页书" .. i, authors = "", deleted = 0 }))
    Assert.is_true(NoteDB.upsert("local", sid, 0, JSON.encode({
        ann({ datetime = "2026-10-01 00:00:00", text = "分页条目" .. i, chapter = "附录" }),
    }), 100 + i))
end
local p1 = Query.books({ page = 1 })
Assert.eq(p1.total, 33)
Assert.eq(p1.pages, 2)
Assert.eq(#p1.books, Query.PAGE)
local p2 = Query.books({ page = 2 })
Assert.eq(#p2.books, 3)
for i = 1, 31 do
    require("book.note_db").removeIdentity("local", string.format("page-book-%02d", i))
end
Assert.eq(Query.books().total, 2)

-- 详情。
local key = all.items[1].key
local detail = Query.item(key)
Assert.eq(detail.text, "地方志摘录")
Assert.eq(detail.note, "要查出处")
Assert.eq(detail.chapter, "风俗")
Assert.eq(detail.drawer, "lighten")

-- 导出 Markdown：书 → 章 → 引用 → 备注，且不含墓碑。
local path = Query.exportFile()
Assert.not_nil(path)
local body = assert(io.open(path, "rb")):read("*a")
Assert.is_true(body:find("# 地方志", 1, true) ~= nil)
Assert.is_true(body:find("## 风俗", 1, true) ~= nil)
Assert.is_true(body:find("地方志摘录", 1, true) ~= nil)
Assert.is_true(body:find("要查出处", 1, true) ~= nil)
Assert.is_true(body:find("# 活着", 1, true) ~= nil)
Assert.is_nil(body:find("已删", 1, true))
Assert.is_nil(body:find("书签无划线", 1, true))
os.remove(path)

-- HTTP 分发。
local function call(method, action, params)
    local status, result
    Remote.handle(method, action, params or {}, function(s, r) status, result = s, r end)
    return status, result
end

local st, res = call("GET", "list", { page = "1", q = "地方志" })
Assert.eq(st, 200)
Assert.eq(res.total, 1)
st, res = call("GET", "books", { page = "1" })
Assert.eq(st, 200)
Assert.eq(#res.books, 2)
Assert.eq(res.total, 2)
Assert.eq(res.pages, 1)
st, res = call("GET", "books", { q = "活着" })
Assert.eq(st, 200)
Assert.eq(res.total, 1)
Assert.eq(res.books[1].title, "活着")
st, res = call("GET", "item", { key = key })
Assert.eq(st, 200)
Assert.eq(res.note, "要查出处")
st, res = call("GET", "item", { key = "bad" })
Assert.eq(st, 400)
st, res = call("POST", "update", { key = key, note = "改过了" })
Assert.eq(st, 200)
Assert.eq(res.note, "改过了")
Assert.eq(Query.item(key).note, "改过了")

local throwaway = ann({ datetime = "2026-11-03 09:00:00", text = "一次性条目", chapter = "附录" })
Assert.is_true(NoteDB.upsert("local", "book-2", 1, JSON.encode({ throwaway }), 400))
local del_key = Note.itemKey("local", "book-2", 1, throwaway)
st, res = call("POST", "remove", { key = del_key })
Assert.eq(st, 200)
Assert.eq(res.removed, 1)
Assert.is_nil(Query.item(del_key))

st, res = call("GET", "missing", {})
Assert.eq(st, 404)

local file = Remote.download("export")
Assert.not_nil(file)
Assert.eq(file.filename, "moon-notes.md")
Assert.not_nil(file.path)
Assert.is_true((assert(io.open(file.path, "rb")):read("*a")):find("活着句子1", 1, true) ~= nil)
os.remove(file.path)
Assert.is_nil(Remote.download("list"))

-- 查询失败必须透传为失败，不返回空/部分列表，也不能生成导出附件。
do
    local each = NoteDB.each
    local tmpname = require("utils.paths").tmpname
    for _idx, partial in ipairs({ false, true }) do
        NoteDB.each = function(fn)
            if partial then fn({
                source_id = "local", stable_id = "book-2", chapter_idx = 0,
                payload = NoteDB.get("local", "book-2", 0).payload,
            }) end
            return false
        end
        require("utils.paths").tmpname = function() error("查询失败后不得创建导出") end
        for _i, action in ipairs({ "list", "books" }) do
            local result, err = Query[action]()
            Assert.is_nil(result)
            Assert.eq(err, "query failed")
            local status, response = call("GET", action)
            Assert.eq(status, 500)
            Assert.not_nil(response.error)
        end
        local failed_path, err = Query.exportFile()
        Assert.is_nil(failed_path)
        Assert.eq(err, "query failed")
        Assert.is_nil(Remote.download("export"))
        Assert.eq(call("GET", "export"), 500)
    end
    NoteDB.each = each
    require("utils.paths").tmpname = tmpname
end

-- 写入中途或 close 落盘失败：停止写入、关闭并清残件，HTTP 不发成功附件。
do
    local open, remove = io.open, os.remove
    for _idx, close_failure in ipairs({ false, true }) do
        local writes, closes, removed = 0, 0, nil
        local err = "No space left on device"
        io.open = function(pathname, mode)
            Assert.eq(mode, "wb")
            local file_handle = {}
            function file_handle:write(_text)
                writes = writes + 1
                if not close_failure and writes == 3 then return nil, err end
                return self
            end
            function file_handle:close()
                closes = closes + 1
                if close_failure then return nil, err end
                return true
            end
            os.remove = function(target) Assert.eq(target, pathname); removed = target; return true end
            return file_handle
        end
        local failed_path, export_err = Query.exportFile()
        Assert.is_nil(failed_path)
        Assert.eq(export_err, err)
        Assert.eq(closes, 1)
        Assert.not_nil(removed)
        if not close_failure then Assert.eq(writes, 3, "第一次写失败后不得继续写") end
        writes = 0
        Assert.is_nil(Remote.download("export"))
        Assert.eq(call("GET", "export"), 500)
    end
    io.open, os.remove = open, remove
end

Base.close()
for _idx, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(db_path .. suffix) end
