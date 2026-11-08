--[[--
京东书架不完整快照：合法成员可更新，坏 ID 不能让缺席的本地书下架。

@module tests.source.jdread.shelf_spec
--]]

local Assert = require("support.assert")
local Config = require("support.config")
local Stubs = require("support.stubs")
local path = Config.dir() .. "/jdread-partial-shelf.sqlite3"
for _idx, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(path .. suffix) end
package.loaded["utils.paths"] = {
    dbPath = function() return path end,
    sanitizeSourceId = function(id) return id end,
}
local DB = require("utils.db")
local BookDB = require("book.books_db")
for idx = 1, 3 do
    Assert.is_true(BookDB.upsertRemote({
        source_id = "jdread", stable_id = tostring(idx), title = "书" .. idx, deleted = 0,
    }))
end
local client = require("source.jdread.client"):new{ cookie = "test", uuid = "test" }
local partial = true
function client:apiGetAsync(request_path, _query, cb)
    if request_path == "/jdread/api/bookshelf/sort" then
        local ids = partial and { { ebook_id = 1 }, { ebook_id = false }, { ebook_id = 3 } }
            or { { ebook_id = 1 }, { ebook_id = 3 } }
        cb({ data = { book_ids = ids } })
    else
        cb({ data = { { ebook_id = 1, name = "一" }, { ebook_id = 3, name = "三" } } })
    end
    return { cancel = function() end }
end
local function sync()
    local result, reason
    require("source.shelf").syncAsync("jdread", client, require("source.jdread.mapper").shelfList,
        { force = true }, function(value, err) result, reason = value, err end)
    Stubs.flush()
    Assert.is_nil(reason)
    Assert.not_nil(result)
    return result
end
local result = sync()
Assert.eq(BookDB.get("jdread", "1").title, "一", "合法成员照常更新")
Assert.eq(BookDB.get("jdread", "2").deleted, 0, "坏行不是远端明确移除")
Assert.eq(result.hidden, 0)
partial = false
result = sync()
Assert.eq(BookDB.get("jdread", "2").deleted, 1, "完整快照仍按缺席下架")
Assert.eq(result.hidden, 1)
DB.close()
for _idx, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(path .. suffix) end
