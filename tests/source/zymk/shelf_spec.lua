--[[--
知音漫客收藏：只读拉取、空快照、坏响应、离线、取消与换号隔离。

@module tests.source.zymk.shelf_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch, inject-field

local Assert = require("support.assert")
local Stubs = require("support.stubs")
local JSON = require("support.json_stub")
local Text = require("utils.text")
package.loaded["json"] = JSON
local cfg = { account = { type = "mkxq", openid = "synthetic-account" } }
local connected, expired, automatic = true, false, true
package.loaded["utils.settings"] = { getSource = function() return cfg end }
package.loaded["source.auth"] = { expired = function() return expired end }
package.loaded["ui/network/manager"] = { isConnected = function() return connected end }
local requests = {}
local data = { ubook = { { comic_id = 4982, comic_name = "测试漫画", addtime = 1700000000123 } } }
package.loaded["http.request"] = { post = function(url, body, opts, cb)
    local request = { url = url, body = body, opts = opts, cb = cb }
    requests[#requests + 1] = request
    if automatic then cb(JSON.encode({ status = 0, data = data })) end
    return { cancel = function() request.cancelled = true end }
end }
local written, options, calls = nil, nil, 0
package.loaded["book.books_db"] = {
    reconcile = function(source_id, books, opts)
        Assert.eq(source_id, "zymk")
        written, options, calls = books, opts, calls + 1
        return true, 0
    end,
}
local Mapper = require("source.zymk.mapper")
local Source = require("source.zymk")
local source = Source.new()
local result, reason
local function done(value, err) result, reason = value, err end

Assert.len(Mapper.shelf({}), 0)
Assert.len(Mapper.shelf({ urecord = {} }), 0)
Assert.is_nil(Mapper.shelf({ wrong = {} }))
Assert.is_nil(Mapper.shelf({ ubook = false }))
Assert.is_nil(Mapper.shelf({ ubook = { [2] = data.ubook[1] } }))
Assert.is_nil(Mapper.shelf({ ubook = { { comic_id = "bad", comic_name = "坏身份" } } }))
Assert.is_nil(Mapper.shelf({ ubook = { { comic_id = 1 } } }))

source:syncBooksAsync({ force = true }, done)
Assert.eq(result.pulled, 1)
Assert.eq(result.pushed, 0)
Assert.is_false(result.skipped)
Assert.eq(written[1].stable_id, "4982")
Assert.eq(written[1].cover, Mapper.cover(4982))
Assert.eq(written[1].inserted_at, 1700000000)
Assert.is_true(options.force)
Assert.is_true(options.inserted_at_from_row)
Assert.is_nil(options.allow_empty)
Assert.eq(requests[1].body, Text.formEncode(cfg.account), "不带 sync，不合并浏览器本地记录")
Assert.is_nil(requests[1].opts.headers.Cookie)
Assert.is_false(requests[1].opts.allow_redirects)
Assert.matches(requests[1].url, "^https://www%.zymk%.cn/apinew/getuserrecord/$")
local count = #requests
source:syncBooksAsync({ dirty_only = true }, done)
Stubs.flush()
Assert.is_true(result.skipped)
Assert.eq(#requests, count)

data = {}
source:syncBooksAsync({ force = true }, done)
Assert.eq(result.pulled, 0)
Assert.is_nil(options.allow_empty, "空快照不能清空本地书架")
automatic = false
local reconciled = calls
source:syncBooksAsync(nil, done)
requests[#requests].cb("<html>login</html>")
Assert.is_nil(result)
Assert.eq(calls, reconciled)
Assert.eq(reason, "登录响应无效")
source:syncBooksAsync(nil, done)
requests[#requests].cb(nil, "network failed")
Assert.eq(reason, "network failed")
Assert.eq(calls, reconciled)
local handle = source:syncBooksAsync(nil, done)
local pending = requests[#requests]
handle.cancel()
pending.cb(JSON.encode({ status = 0, data = data }))
Assert.is_true(pending.cancelled)
Assert.eq(calls, reconciled)

source:syncBooksAsync(nil, done)
pending = requests[#requests]
local account = cfg.account
cfg.account = { type = "mkxq", openid = "another-account" }
pending.cb(JSON.encode({ status = 0, data = data }))
Assert.eq(reason, "登录状态已变化，请重试")
Assert.eq(calls, reconciled)
count = #requests
source:syncBooksAsync(nil, done)
Stubs.flush()
Assert.eq(#requests, count)
Assert.eq(reason, "登录状态已变化，请重试")
cfg.account = account
connected = false
source:syncBooksAsync(nil, done)
Stubs.flush()
Assert.eq(reason, "网络不可用，请先连接 Wi-Fi")
Assert.eq(#requests, count)
connected, expired = true, true
source:syncBooksAsync(nil, done)
Stubs.flush()
Assert.eq(reason, "请先登录知音漫客")
Assert.eq(#requests, count)
cfg.account = nil
Source.new():syncBooksAsync(nil, done)
Stubs.flush()
Assert.is_true(result.skipped)
Assert.eq(#requests, count)
Assert.is_false(source:capabilities().shelf_push)
