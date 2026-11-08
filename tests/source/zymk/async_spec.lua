--[[--
知音漫客：同步前级与异步后级的取消句柄、搜索分页与失败语义。

@module tests.source.zymk.async_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local Stubs = require("support.stubs")
local JSON = require("support.json_stub")
package.loaded["json"] = JSON
local pending, cancelled, mode = nil, {}, "catalog"
local html = '<meta property="og:novel:book_name" content="测试"><a href="1.html">首话</a>'
local filters = '<dt class="attr-hd">题材</dt><dd class="attr-bd"><a data-tag="5" title="热血">热血</a></dd>'
package.loaded["http.request"] = {
    header = function(res, key) return res.headers[key] end,
    get = function(url, _opts, cb)
        local kind
        if url:find("/getchapterlist", 1, true) or url:find("/allComic/", 1, true) then
            kind = "list"
            pending = cb
        elseif url:find("/sort/all.html", 1, true) then
            kind = "filters"
            cb(filters)
        elseif url:find("/1.html", 1, true) then
            kind = "redirect"
            cb(nil, "HTTP 301", { code = 301, headers = {
                location = mode == "bad_redirect" and "https://evil.test/kanman.com/123/"
                    or "https://www.kanman.com/123/first.html",
            } })
        elseif url:find("getsortlist", 1, true) then
            local page = tonumber(url:match("page=(%d+)"))
            kind = "page" .. page
            if mode == "search_error" and page == 2 then cb(nil, "网络故障")
            elseif mode == "search_async" and page == 2 then pending = cb
            else
                cb(JSON.encode({ status = 0, data = { page = { total_page = 2, comic_list = {
                    { comic_id = page, comic_name = "结果" .. page },
                } } } }))
            end
        else
            kind = "detail"
            cb(html)
        end
        return { cancel = function() cancelled[kind] = true end }
    end,
}
local Client = require("source.zymk.client")
local called = false
local handle = Client.catalogAsync("1", function() called = true end)
handle.cancel()
Assert.is_true(cancelled.list)
Assert.is_nil(cancelled.detail)
Assert.is_nil(cancelled.redirect)
pending(JSON.encode({ status = 0, data = {} }))
Assert.is_false(called)

cancelled = {}
handle = Client.libraryAsync(function() called = true end)
handle.cancel()
Assert.is_true(cancelled.list)
Assert.is_nil(cancelled.filters)
pending(JSON.encode({ status = 0, data = {} }))
Assert.is_false(called)

mode = "bad_redirect"
Client.catalogAsync("1", function(data, err)
    Assert.is_nil(data)
    Assert.eq(err, "HTTP 301")
end)
mode = "catalog"
Client.catalogAsync("1", function(data, err)
    Assert.is_nil(data)
    Assert.eq(err, "响应无效")
end)
pending(JSON.encode({ status = 1, data = { { chapter_name = "首话", chapter_newid = "first", order_num = 1 } } }))

mode = "search"
Client.searchAsync("结果", function(data, err)
    Assert.is_nil(err)
    Assert.len(data, 2)
    Assert.eq(data[2].stable_id, "2")
end)
mode = "search_error"
Client.searchAsync("结果", function(data, err)
    Assert.is_nil(data)
    Assert.eq(err, "网络故障")
end)
mode, cancelled = "search_async", {}
handle = Client.searchAsync("结果", function() called = true end)
handle.cancel()
Assert.is_true(cancelled.page2)
Assert.is_nil(cancelled.page1)
pending(JSON.encode({ status = 0, data = { page = { comic_list = {} } } }))
Assert.is_false(called)

handle = Client.imagesAsync("bad", function() called = true end)
handle.cancel()
Stubs.flush()
Assert.is_false(called)
