--[[--
豆瓣书架分组、分类口径和多阶段取消。

@module tests.source.douban.shelf_spec
--]]
---@diagnostic disable: undefined-field, missing-fields

local Assert = require("support.assert")
local Json = require("support.json_stub")
local cfg = { logged_in = true, user_id = "42", cookie = "session=test" }
package.preload["json"] = function() return Json end
package.preload["utils.settings"] = function()
    return { getSource = function() return cfg end, get = function() return {} end }
end

local Mapper = require("source.douban.mapper")
local folders = { data = { user = { bookshelf = { folders = { list = {
    { id = 20, name = "另一组", libraryList = { list = { { worksId = "1" }, { worksId = "3" } } } },
    { id = 10, name = "收藏", libraryList = { list = { { worksId = "1" } } } },
} } } } } }
local works = { data = { worksList = {
    { id = "1", title = "甲", isOrigin = true },
    { id = "2", title = "乙", isOrigin = false },
    { id = "3", title = "丙", kinds = { { shortName = "科幻" } } },
} } }
local groups = Mapper.shelfGroups(folders, { 10, 20 })
Assert.eq(groups["1"], "收藏")
Assert.eq(groups["3"], "另一组")
local books = Mapper.shelfWorks(works, groups, { "1", "2", "3" })
Assert.eq(books[1].category, "收藏")
Assert.is_nil(books[2].category)
Assert.is_true(books[2].category_authoritative)
Assert.eq(books[3].category, "另一组")
cfg.category_as_group = false
books = Mapper.shelfWorks(works, groups)
Assert.eq(books[1].category, "原创")
Assert.eq(books[2].category, "出版")
Assert.eq(books[3].category, "科幻")
cfg.category_as_group = nil
Assert.is_nil(Mapper.folderIds({ folderIds = { "10", false } }))
Assert.is_nil(Mapper.folderIds({ folderIds = { unexpected = true } }))
Assert.is_nil(Mapper.folderIds({}))
Assert.eq(#Mapper.folderIds({ folderIds = {} }), 0)
Assert.is_nil(Mapper.shelfGroups(folders, { 10, 30 }))
Assert.is_nil(Mapper.shelfGroups({ errors = { { message = "denied" } }, data = folders.data }, { 10, 20 }))
Assert.is_nil(Mapper.shelfGroups({ data = { user = { bookshelf = { folders = { list = {
    { id = 10, name = "收藏", libraryList = {} },
} } } } } }, { 10 }))
Assert.is_nil(Mapper.shelfWorks({ errors = { { message = "partial" } }, data = works.data }, groups))
Assert.is_nil(Mapper.shelfWorks(works, groups, { "1", "missing" }))
Assert.is_nil(Mapper.shelfIds({ worksIds = { "1", false } }))

local BookDB = require("book.books_db")
Assert.is_true(BookDB.upsertRemote({ source_id = "douban", stable_id = "2", title = "乙", category = "旧题材" }))
Assert.is_true(BookDB.upsertRemote(Mapper.shelfWorks(works, groups)[2]))
Assert.is_nil(BookDB.get("douban", "2").category)

local requests, deferred, defer_works = {}, false, false
local folder_wire, folder_error = { folderIds = { 10, 20 } }, nil
package.preload["http.request"] = function()
    return {
        header = function() end, headerAll = function() return {} end,
        request = function(opts, cb)
            local req = { opts = opts }
            requests[#requests + 1] = req
            local wire, body, err
            if opts.url == "https://read.douban.com/" then body = "CSRF_TOKEN='test';"
            elseif opts.url:find("/folder/", 1, true) then wire, err = folder_wire, folder_error
            elseif opts.url:find("/j/bookshelf/", 1, true) then wire = { worksIds = { "1", "2", "3" } }
            else
                local payload = Json.decode(opts.body)
                wire = payload.extensions.persistedQuery.sha256Hash == Mapper.SHELF_FOLDERS_HASH and folders or works
            end
            req.reply = function() cb(not err and { code = 200, body = body or Json.encode(wire) } or nil, err) end
            if not deferred and not (defer_works and opts.body and opts.body:find(Mapper.SHELF_WORKS_HASH, 1, true)) then
                req.reply()
            end
            return { cancel = function() req.cancelled = true end }
        end,
    }
end
local Client = require("source.douban.client")
local result, failure
Client.shelfAsync(function(rows, err) result, failure = rows, err end)
Assert.eq(#result, 3)
Assert.is_nil(failure)
Assert.eq(result[1].category, "收藏")
for _idx, req in ipairs(requests) do
    Assert.is_true(req.opts.method == "GET" or req.opts.url == "https://read.douban.com/j/graphql")
end
cfg.category_as_group, requests = false, {}
Client.shelfAsync(function(rows) result = rows end)
Assert.eq(result[1].category, "原创")
Assert.eq(#requests, 2)
cfg.category_as_group = nil
folder_wire = { folderIds = {} }
Client.shelfAsync(function(rows) result = rows end)
Assert.is_nil(result[1].category)
folder_wire = {}
Client.shelfAsync(function(rows, err) result, failure = rows, err end)
Assert.is_nil(result)
Assert.is_true(failure ~= nil)
folder_error = "network failed"
Client.shelfAsync(function(rows, err) result, failure = rows, err end)
Assert.is_nil(result)
Assert.eq(failure, "network failed")
folder_error, folder_wire, deferred = nil, { folderIds = { 10, 20 } }, true
for cancel_at = 0, 4 do
    Client.reset()
    local calls = 0
    local job = Client.shelfAsync(function() calls = calls + 1 end)
    for _step = 1, cancel_at do requests[#requests].reply() end
    local current, count = requests[#requests], #requests
    job.cancel()
    Assert.is_true(current.cancelled)
    current.reply()
    Assert.eq(calls, 0)
    Assert.eq(#requests, count)
end
deferred, defer_works = false, true
Client.reset()
local calls = 0
local job = Client.shelfAsync(function() calls = calls + 1 end)
local pending = requests[#requests]
job.cancel()
Assert.is_true(pending.cancelled)
pending.reply()
Assert.eq(calls, 0)
deferred, defer_works = true, false
job = Client.shelfAsync(function(rows, err) result, failure = rows, err end)
cfg.cookie = "session=other"
requests[#requests].reply()
Assert.is_nil(result)
Assert.eq(failure, "登录状态已变化，请重试")
job.cancel()
