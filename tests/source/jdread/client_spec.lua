--[[--
京东读书客户端分页与旧阅读接口离线用例。

@module tests.source.jdread.client_spec
--]]

local Assert = require("support.assert")
local JSONStub = require("support.json_stub")

package.preload["json"] = function()
    return { decode = JSONStub.decode, encode = JSONStub.encode }
end

local requests = {}
package.preload["http.request"] = function()
    return {
        get = function(url, opts, cb)
            requests[#requests + 1] = { url = url, opts = opts }
            if url:find("/jdread/api/bookshelf/sort", 1, true) then
                cb('{"data":{"book_ids":[{"ebook_id":2},{"ebook_id":1}]},"result_code":0}')
            elseif url:find("/jdread/api/ebooks/lite/2,1", 1, true) then
                cb('{"data":[{"ebook_id":2,"name":"二"},{"ebook_id":1,"name":"一"}],"result_code":0}')
            elseif url:find("/jdread/api/search/v2", 1, true) then
                cb('{"data":{"product_search_infos":[{"product_id":3,"product_name":"搜索书"}],'
                    .. '"total_count":1},"result_code":0}')
            elseif url:find("/recommend", 1, true) then
                cb('{"data":[{"ebook_id":4,"name":"推荐书"}],"result_code":0}')
            else
                cb('{"code":"-1","msg":"stop"}')
            end
            return { cancel = function() end }
        end,
        post = function(url, body, opts, cb)
            requests[#requests + 1] = { url = url, body = body, opts = opts }
            cb('{"data":[],"result_code":0,"message":"SUCCESS"}')
            return { cancel = function() end }
        end,
    }
end

package.loaded["json"] = nil
package.loaded["http.request"] = nil
package.loaded["source.jdread.protocol"] = nil
package.loaded["source.jdread.client"] = nil

local Client = require("source.jdread.client")
local client = Client:new{ cookie = "thor=test", uuid = "h5-test" }

do
    Assert.is_true(client:configured())
    local wire, err
    client:shelfSyncAsync(function(value, e) wire, err = value, e end)
    Assert.is_nil(err)
    Assert.len(wire.data.books, 2)
    Assert.eq(wire.data.books[1].ebook_id, 2)
    Assert.matches(requests[1].url, "/jdread/api/bookshelf/sort%?")
    Assert.matches(requests[2].url, "/jdread/api/ebooks/lite/2,1%?")
    Assert.eq(requests[1].opts.headers.Cookie, "thor=test")
end

do
    local batched = Client:new{ cookie = "thor=test", uuid = "h5-test" }
    local paths = {}
    function batched:apiGetAsync(path, _, cb)
        paths[#paths + 1] = path
        if path == "/jdread/api/bookshelf/sort" then
            local ids = {}
            for i = 1, 20 do ids[i] = { ebook_id = i } end
            cb({ data = { book_ids = ids } })
        else
            local rows = {}
            for id in path:match("/ebooks/lite/(.+)$"):gmatch("[^,]+") do
                rows[#rows + 1] = { ebook_id = tonumber(id) }
            end
            cb({ data = rows })
        end
        return { cancel = function() end }
    end
    local wire
    batched:shelfSyncAsync(function(value) wire = value end)
    Assert.len(wire.data.books, 20)
    Assert.eq(wire.data.total, 20)
    Assert.matches(paths[2], "/ebooks/lite/1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18$")
    Assert.matches(paths[3], "/ebooks/lite/19,20$")
end

do
    local wire, err
    client:searchAsync("计算机", 2, 30, function(value, e) wire, err = value, e end)
    local req = requests[#requests]
    Assert.is_nil(err)
    Assert.eq(wire.data.total_count, 1)
    Assert.matches(req.url, "^https://e%.m%.jd%.com/jdread/api/search/v2%?")
    Assert.matches(req.url, "[?&]keyword=%%E8%%AE%%A1%%E7%%AE%%97%%E6%%9C%%BA")
    Assert.matches(req.url, "[?&]page=2")
    Assert.matches(req.url, "[?&]page_size=30")
    Assert.matches(req.url, "[?&]cv=3%.4%.0")
end

do
    local paged = Client:new{ cookie = "thor=test", uuid = "h5-test" }
    local pages = {}
    function paged:apiGetAsync(_, params, cb)
        pages[#pages + 1] = params.page
        local rows = {}
        local count = params.page == 1 and 30 or 1
        for i = 1, count do rows[i] = { product_id = #pages * 100 + i } end
        cb({ data = { product_search_infos = rows, total_count = 31 } })
        return { cancel = function() end }
    end
    local wire
    paged:searchAsync("Lua", 1, 200, function(value) wire = value end)
    Assert.len(wire.data.product_search_infos, 31)
    Assert.eq(pages[1], 1)
    Assert.eq(pages[2], 2)
    Assert.len(pages, 2)
end

do
    local wire, err
    client:recommendAsync("30451107", function(value, e) wire, err = value, e end)
    local req = requests[#requests]
    Assert.is_nil(err)
    Assert.eq(wire.data[1].ebook_id, 4)
    Assert.matches(req.url, "/jdread/api/ebook/30451107/recommend%?")
end

do
    local wire, err
    client:addToShelfAsync("30533530", function(value, e) wire, err = value, e end)
    local req = requests[#requests]
    Assert.is_nil(err)
    Assert.not_nil(wire)
    Assert.matches(req.url, "/jdread/api/bookshelf/book/sync%?")
    local body = require("json").decode(req.body)
    Assert.eq(body.first_sync, 1)
    Assert.eq(body.items[1].action, 0)
    Assert.eq(body.items[1].ebook_id, 30533530)
end

do
    local _, err
    local first = #requests + 1
    client:chapterInfosAsync("30451107", function(value, e) _, err = value, e end)
    local req = requests[first]
    Assert.matches(req.url, "^https://cread%.jd%.com/read/lC%.action%?")
    Assert.matches(req.url, "[?&]readType=3")
    Assert.matches(req.url, "k=c32bc1eceb889c09")
    Assert.matches(requests[first + 1].url, "[?&]readType=0")
    Assert.matches(requests[first + 2].url, "[?&]readType=1")
    Assert.eq(err, "stop")
end

do
    local auto = Client:new{ cookie = "thor=test", uuid = "h5-test" }
    local modes = {}
    function auto:readerGetAsync(_, query, cb)
        modes[#modes + 1] = query.readType
        if query.readType == 0 then
            cb({ ok = true })
        else
            cb(nil, "denied", true)
        end
        return { cancel = function() end }
    end

    local wire
    auto:chapterInfosAsync("book", function(value) wire = value end)
    Assert.is_true(wire.ok)
    Assert.eq(modes[1], 3)
    Assert.eq(modes[2], 0)

    modes = {}
    auto:chapterContentAsync("book", "chapter", function(value) wire = value end)
    Assert.is_true(wire.ok)
    Assert.eq(modes[1], 0)
    Assert.len(modes, 1)
end

do
    local wire, err
    client:getProgressAsync("30451107", function(value, e) wire, err = value, e end)
    local req = requests[#requests]
    Assert.is_nil(err)
    Assert.not_nil(wire)
    Assert.matches(req.url, "^https://e%.m%.jd%.com/jdread/api/marker/sync%?")
    Assert.eq(req.opts.content_type, "application/json")
    local body = require("json").decode(req.body)
    Assert.eq(body[1].ebook_id, 30451107)
    Assert.eq(body[1].format, 1)
end
