--[[--
source.wechat.shelf_import：大快照落盘、分批入库、收尾对账（书库与游标桩掉）。

@module tests.source.wechat.shelf_import_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, inject-field

local Assert = require("support.assert")
local Config = require("support.config")

local dir = Config.dir() .. "/shelf_import_spec"
os.execute("mkdir -p '" .. dir .. "'")

local upserted, hidden_keep, saved = {}, nil, nil
package.loaded["utils.paths"] = {
    sourceCacheDir = function() return dir end,
    ensureDir = function() return true end,
}
package.loaded["book.books_db"] = {
    upsertRemoteMany = function(rows)
        for _idx, row in ipairs(rows) do upserted[#upserted + 1] = row end
        return true
    end,
    hideMissing = function(_source_id, keep)
        hidden_keep = keep
        return 2
    end,
}
package.loaded["source.wechat.eink"] = { save = function(patch) saved = patch end }
package.loaded["utils.settings"] = { getSource = function() return { wr_vid = "v1" } end }
package.loaded["source.wechat.shelf_import"] = nil
package.loaded["source.wechat.mapper"] = nil

local ShelfImport = require("source.wechat.shelf_import")

Assert.is_nil(ShelfImport.size())
Assert.is_true(ShelfImport.stash("{}"))
Assert.eq(ShelfImport.size(), 2)

local ids = ShelfImport.ingest({
    books = { { bookId = "b1", title = "书一" }, { bookId = "b2", title = "书二" } },
    bookProgress = { { bookId = "b1", progress = 50 } },
    archive = { { name = "分组", bookIds = { "b1" } } },
})
Assert.len(ids, 2)
Assert.eq(upserted[1].source_id, "wechat")
Assert.eq(upserted[1].deleted, 0)
Assert.eq(upserted[1].percent, 50)

Assert.eq(ShelfImport.commit(ids, 77), 2)
Assert.eq(hidden_keep, ids)
Assert.eq(saved.shelf_cursor.synckey, 77)
Assert.eq(saved.shelf_cursor.vid, "v1")
Assert.is_nil(ShelfImport.size())
