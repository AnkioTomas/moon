--[[--
source.wechat.shelf_import：大快照落盘、分批入库、收尾对账（书库与游标桩掉）。

@module tests.source.wechat.shelf_import_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, inject-field

local Assert = require("support.assert")
local Config = require("support.config")
local Stubs = require("support.stubs")

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
local oversize_next = false
package.loaded["source.wechat.eink"] = {
    save = function(patch) saved = patch end,
    callAsync = function(_method, _path, _opts, cb)
        if oversize_next then
            oversize_next = false
            cb({ body = "{}" }, nil, { oversize = true })
        else
            cb({})
        end
        return { cancel = function() end }
    end,
}
package.loaded["utils.awake"] = { hold = function() end }
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

-- 后台同步发现/重试待导入快照时不弹窗；用户手动刷新才打开导入页。
do
    local Client = require("source.wechat.client")
    Assert.is_true(ShelfImport.stash("{}"))
    local opened = 0
    require("utils.extension").add("web.open_page", function() opened = opened + 1 end)
    local got
    local handle = Client.shelfSyncAsync({}, function(data, err) got = { data, err } end, true, false)
    Assert.is_true(handle ~= nil)
    Stubs.flush()
    Assert.eq(opened, 0, "后台重试不重复弹出待导入页")
    Assert.is_nil(got[1])
    Assert.eq(got[2], ShelfImport.TOO_LARGE)

    got = nil
    handle = Client.shelfSyncAsync({}, function(data, err) got = { data, err } end, true, true)
    Assert.is_true(handle ~= nil)
    Stubs.flush()
    Assert.eq(opened, 1, "手动强制刷新可重新打开待导入页")
    Assert.is_nil(got[1])
    Assert.eq(got[2], ShelfImport.TOO_LARGE)
    ShelfImport.discard()

    -- 首次后台全量超限只保存快照，不能在用户已进入阅读器后突然弹页。
    oversize_next = true
    got = nil
    handle = Client.shelfSyncAsync({}, function(data, err) got = { data, err } end, true, false)
    Assert.is_true(handle ~= nil)
    Assert.eq(opened, 1, "后台首次遇到超大书架只保存快照")
    Assert.is_nil(got[1])
    Assert.eq(got[2], ShelfImport.TOO_LARGE)
    Assert.is_true(ShelfImport.size() ~= nil)
    ShelfImport.discard()

    -- 显式刷新触发的全量超限仍应直接打开导入页。
    oversize_next = true
    got = nil
    handle = Client.shelfSyncAsync({}, function(data, err) got = { data, err } end, true, true)
    Assert.is_true(handle ~= nil)
    Assert.eq(opened, 2, "手动刷新遇到超大书架打开导入页")
    Assert.is_nil(got[1])
    Assert.eq(got[2], ShelfImport.TOO_LARGE)
    ShelfImport.discard()
end
