--[[--
iRead 搜索元数据持久化、重启后加架、写后确认与源编排取消。

@module tests.source.iread.source_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch, inject-field

local Assert = require("support.assert")
local Config = require("support.config")
local Stubs = require("support.stubs")
local sqlite_ok = pcall(require, "lua-ljsqlite3/init")
if not sqlite_ok then Assert.skip("当前离线环境没有 ljsqlite3 Lua 模块") end
package.loaded.json = require("support.json_stub")
local path = Config.dir() .. "/iread_source_spec.sqlite3"
for _index, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(path .. suffix) end
local Paths = require("utils.paths")
package.loaded["utils.paths"] = setmetatable({ dbPath = function() return path end }, { __index = Paths })
local BookDB = require("book.books_db")
local Store = require("book.store")
local Base = require("source.base")
local row = { name = "测试书", bookUrl = "https://example.test/book", sourceId = 7, variable = { key = "value" } }
local requests, shelf_replies = {}, {}
local function pending(kind, cb, data)
    local request = { kind = kind, cb = cb, data = data }
    requests[#requests + 1] = request
    return { cancel = function() request.cancelled = true end }
end
package.loaded["source.iread.client"] = {
    credential = function() return { token = "test" } end,
    searchAsync = function(_keyword, cb) return Base.defer(cb, { row }) end,
    shelfAsync = function(cb)
        local job = pending("shelf", cb)
        local rows = table.remove(shelf_replies, 1)
        if rows then cb(rows) end
        return job
    end,
    favouriteAsync = function(book, cb)
        local job = pending("toggle", cb, book)
        cb(true)
        return job
    end,
    chaptersAsync = function(book, cb) return pending("toc", cb, book) end,
    exploreRulesAsync = function(cb)
        local job = pending("rules", cb)
        cb({ { id = 7, exploreUrl = { { title = "分类", url = "https://example.test/category" } } } })
        return job
    end,
    exploreAsync = function(_id, _url, cb) return pending("explore", cb) end,
}
local remote
package.loaded["source.shelf"] = {
    syncAsync = function(_id, adapter, _mapper, _opts, cb)
        remote = adapter
        return Base.defer(cb, { skipped = true })
    end,
}
local IRead = require("source.iread")
local source = IRead.new()
local result, reason, calls = nil, nil, 0
local function done(value, err) result, reason, calls = value, err, calls + 1 end
source:searchAsync("测试", function(res)
    Store.rememberMany(res.data)
end)
Stubs.flush()
local stored = BookDB.get("iread", row.name)
Assert.eq(stored.meta.source.iread.bookUrl, row.bookUrl)
Assert.eq(stored.meta.source.iread.variable.key, "value")
Assert.eq(stored.deleted, 1, "保存书城结果不能自动上架")

source = IRead.new()
local identity = { source_id = "iread", stable_id = row.name }
local handle = source:loadTocAsync(identity, done, true)
Assert.len(requests, 1, "重启后目录可使用随书籍持久化的源记录")
Assert.eq(requests[1].kind, "toc")
Assert.eq(requests[1].data.sourceId, 7)
handle:cancel()
Assert.is_true(requests[1].cancelled)

source:syncBooksAsync({}, function() end)
Stubs.flush()
requests, shelf_replies, result, reason, calls = {}, { {} }, nil, nil, 0
handle = remote:addToShelfAsync(row.name, done)
Assert.eq(requests[2].kind, "toggle")
Assert.eq(requests[2].data.bookUrl, row.bookUrl)
Assert.eq(requests[3].kind, "shelf")
Assert.eq(calls, 0, "收藏接口成功不代表书架已改变")
requests[3].cb({ row })
Assert.is_true(result)
Assert.eq(calls, 1)

requests, shelf_replies, result, reason, calls = {}, { {} }, nil, nil, 0
remote:addToShelfAsync(row.name, done)
requests[3].cb({})
Assert.is_nil(result)
Assert.eq(reason, "iRead 书架更新未生效")

requests, shelf_replies, result, reason, calls = {}, { { row } }, nil, nil, 0
remote:addToShelfAsync(row.name, done)
Assert.is_true(result)
Assert.len(requests, 1, "已在架不重复调用开关接口")

requests, shelf_replies, result, reason, calls = {}, { { row } }, nil, nil, 0
handle = remote:removeFromShelfAsync(row.name, done)
Assert.eq(requests[3].kind, "shelf")
handle:cancel()
Assert.is_true(requests[3].cancelled, "同步回调不能覆盖写后确认的句柄")
requests[3].cb({})
Assert.eq(calls, 0)

requests, shelf_replies, result, reason, calls = {}, { { row } }, nil, nil, 0
remote:removeFromShelfAsync(row.name, done)
requests[3].cb({})
Assert.is_true(result)

requests, shelf_replies, result, reason, calls = {}, { {} }, nil, nil, 0
remote:removeFromShelfAsync(row.name, done)
Assert.is_true(result)
Assert.len(requests, 1, "已移出不能调用开关而重新加入")

requests, shelf_replies, result, reason, calls = {}, { { row } }, nil, nil, 0
handle = source:withRow(identity, true, done, function(book)
    return require("source.iread.client").chaptersAsync(book, done)
end)
Assert.eq(requests[2].kind, "toc")
handle:cancel()
Assert.is_true(requests[2].cancelled)

requests, shelf_replies, result, reason, calls = {}, {}, nil, nil, 0
source.rows = nil
handle = source:fetchShelf(done)
handle:cancel()
requests[1].cb({ row })
Assert.is_nil(source.rows)
Assert.eq(calls, 0)

requests, result, reason, calls = {}, nil, nil, 0
source:browseAsync({}, done)
Assert.len(result.groups[1].chips, 1)
handle = source:browseAsync({ node = "7:1" }, done)
Assert.eq(requests[2].kind, "explore")
handle:cancel()
local before = calls
requests[2].cb({ row })
Assert.eq(calls, before)

local shelf = package.loaded["source.shelf"]
local capture = shelf.syncAsync
package.loaded["source.shelf"] = nil
shelf.syncAsync = require("source.shelf").syncAsync
Assert.is_true(BookDB.setLibraryMembership("iread", row.name, true))
requests, shelf_replies = {}, { {}, {} }
source:syncBooksAsync({ dirty_only = true }, done)
Stubs.flush()
Assert.eq(result.pushed, 0)
Assert.eq(BookDB.get("iread", row.name).sync_status, 0, "写后回读未确认的新加书必须保留脏状态")
Assert.is_true(BookDB.markDeleted("iread", row.name))
requests, shelf_replies = {}, { { row }, { row } }
source:syncBooksAsync({ dirty_only = true }, done)
Stubs.flush()
stored = BookDB.get("iread", row.name)
Assert.eq(stored.deleted, 1)
Assert.eq(stored.sync_status, 0, "远端仍在架时不能撕墓碑")
shelf.syncAsync = capture

local client = require("source.iread.client")
client.credential = function() return nil end
source = IRead.new()
source.explore_rules = { [7] = {
    id = 7, exploreUrl = { { title = "分类", url = "https://example.test/list?page={{page}}" } },
} }
local pages = {}
client.exploreAsync = function(_id, url, cb)
    local page = tonumber(url:match("page=(%d+)"))
    pages[#pages + 1] = page
    local rows = {}
    for index = 1, 20 do
        rows[index] = { name = "分类书" .. ((page - 1) * 20 + index), bookUrl = "https://example.test/book", sourceId = 7 }
    end
    return Base.defer(cb, rows)
end
source:browseAsync({ node = "7:1", limit = 45 }, done)
Stubs.flush()
Assert.len(result.data, 45)
Assert.len(pages, 3)
Assert.eq(pages[3], 3)
Assert.eq(result.groups[1].title, "分类")
Assert.eq(result.data[45].stable_id, "分类书45")

pages = {}
client.exploreAsync = function(_id, url, cb)
    local page = tonumber(url:match("page=(%d+)"))
    pages[#pages + 1] = page
    if page == 1 then return Base.defer(cb, { row }) end
    return Base.defer(cb, nil, "network failed")
end
source:browseAsync({ node = "7:1", limit = 45 }, done)
Stubs.flush()
Assert.is_nil(result)
Assert.eq(reason, "network failed", "第二页失败不能把第一页当成完整分类列表")

source:searchAsync("测试", done)
Stubs.flush()
Assert.len(result.data, 1, "未登录时仍可使用官网公共搜索")
local empty
source:getProgressAsync(identity, function(value, err, meta)
    result, reason, empty = value, err, meta.empty
end)
Stubs.flush()
Assert.is_nil(result)
Assert.is_nil(reason)
Assert.is_true(empty, "游客阅读不应触发云端进度登录提示")

local text
client.contentAsync = function(_book, _raw, _index, cb) return Base.defer(cb, text) end
source.found = { [row.name] = row }
local fetch = source:contentFetcher()
text = "测试段落\n第二段"
fetch(identity, { uid = "0", title = "测试章节", raw = "{}" }, done)
Stubs.flush()
Assert.matches(result.html, "测试段落")
text = '<IMG src="https://example.test/image.png">'
fetch(identity, { uid = "0", title = "测试章节", raw = "{}" }, done)
Stubs.flush()
Assert.is_nil(result)
Assert.eq(reason, "iRead 图片正文暂不支持，请使用网页版阅读")
text = "<p></p>"
fetch(identity, { uid = "0", title = "测试章节", raw = "{}" }, done)
Stubs.flush()
Assert.is_nil(result)
Assert.eq(reason, "iRead 章节内容为空", "不能把剥标签后的空正文缓存成成功")

require("utils.db").close()
for _index, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(path .. suffix) end
