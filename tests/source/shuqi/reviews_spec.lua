--[[--
书旗书评仅归属整本书；分页、空列表与坏响应保持不同语义。

@module tests.source.shuqi.reviews_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local JSON = require("support.json_stub")
package.loaded["json"] = JSON
local Mapper = require("source.shuqi.mapper")
local wire = {
    status = "200", info = { total = 21, count = 2 },
    data = { { mid = 1, bookId = 9, nickName = "读者", text = "书评&amp;感想", pubTime = 1700000000 } },
}
local page = Mapper.reviews(wire, "9")
Assert.eq(page.items[1].text, "书评&感想")
Assert.eq(page.items[1].author, "读者")
Assert.eq(page.pages, 2)
Assert.is_nil(Mapper.reviews(wire, "10"), "不能把别的书评挂到本书")
Assert.is_nil(Mapper.reviews({ status = 200 }, "9"))
Assert.is_nil(Mapper.reviews({ status = 500, data = {}, info = { total = 0, count = 0 } }, "9"))
Assert.len(Mapper.reviews({ status = 200, data = {}, info = { total = 0, count = 0 } }, "9").items, 0)
local requests = {}
package.loaded["http.request"] = {
    get = function(url, opts, cb)
        local request = { url = url, opts = opts, cb = cb }
        requests[#requests + 1] = request
        return { cancel = function() request.cancelled = true end }
    end,
}
local Client = require("source.shuqi.client")
local result, reason
Client.reviewsAsync("9", 2, function(value, err) result, reason = value, err end)
Assert.matches(requests[1].url, "page=2")
Assert.matches(requests[1].url, "bookId=9")
Assert.is_nil(requests[1].opts.headers.Cookie)
requests[1].cb(JSON.encode(wire))
Assert.eq(result.total, 21)
Client.reviewsAsync("9", 1, function(value, err) result, reason = value, err end)
requests[2].cb(nil, "network down")
Assert.is_nil(result)
Assert.eq(reason, "network down")
Client.reviewsAsync("9", 1, function(value, err) result, reason = value, err end)
requests[3].cb("<html>维护</html>")
Assert.is_nil(result)
Assert.eq(reason, "响应无效")
