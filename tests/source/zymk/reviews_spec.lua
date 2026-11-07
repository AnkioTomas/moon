--[[--
知音漫客整书评论：真实成功码、归属、空页、分页、网络与取消。

@module tests.source.zymk.reviews_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local JSON = require("support.json_stub")
local Mapper = require("source.zymk.mapper")
local row = { id = 1, ssid = 101, ssidtype = 0, uname = "测试读者", content = "<p>书评 &amp; 文字</p>", createtime = 1700000000 }
local page = Mapper.reviews("101", 1, { status = 1, data = { row } })
Assert.eq(page.items[1].text, "书评 & 文字")
Assert.eq(page.items[1].author, "测试读者")
Assert.matches(page.items[1].time, "^%d%d%d%d%-%d%d%-%d%d$")
Assert.is_false(page.more)
Assert.len(Mapper.reviews("101", 2, { status = 1, data = {} }).items, 0)
Assert.is_nil(Mapper.reviews("101", 1, { status = 0, data = { row } }))
Assert.is_nil(Mapper.reviews("102", 1, { status = 1, data = { row } }))
row.ssidtype = 1
Assert.is_nil(Mapper.reviews("101", 1, { status = 1, data = { row } }))
row.ssidtype = 0
local full = {}
for index = 1, 20 do full[index] = row end
page = Mapper.reviews("101", 2, { status = 1, data = full })
Assert.is_true(page.more)
Assert.eq(page.pages, 3)

package.loaded["json"] = JSON
local pending, cancelled = nil, false
package.loaded["http.request"] = {
    get = function(url, _opts, cb)
        Assert.matches(url, "^https://community%-hots%.321mh%.com/comment/newgets%?")
        Assert.matches(url, "ssid=101")
        Assert.matches(url, "ssidtype=0")
        Assert.matches(url, "page=2")
        pending = cb
        return { cancel = function() cancelled = true end }
    end,
}
local Client = require("source.zymk.client")
Client.reviewsAsync("101", 2, function(data, err)
    Assert.is_nil(err)
    Assert.len(data.items, 1)
end)
pending(JSON.encode({ status = 1, data = { row } }))
Client.reviewsAsync("101", 2, function(data, err)
    Assert.is_nil(data)
    Assert.eq(err, "网络故障")
end)
pending(nil, "网络故障")
Client.reviewsAsync("101", 2, function(data, err)
    Assert.is_nil(data)
    Assert.eq(err, "响应无效")
end)
pending("bad json")
local called = false
local handle = Client.reviewsAsync("101", 2, function() called = true end)
handle.cancel()
Assert.is_true(cancelled)
pending(JSON.encode({ status = 1, data = { row } }))
Assert.is_false(called)
