--[[--
番茄小说官方接口客户端离线用例。

@module tests.source.fanqie.client_spec
--]]

local Assert = require("support.assert")
local JSONStub = require("support.json_stub")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(value) return value end end
package.preload["json"] = function()
    return { decode = JSONStub.decode, encode = JSONStub.encode }
end

local requests = {}
package.preload["http.request"] = function()
    return {
        get = function(url, opts, cb)
            requests[#requests + 1] = { method = "GET", url = url, opts = opts }
            if url:find("bookshelf/info", 1, true) then
                cb('{"code":0,"data":{"book_shelf_info":[{"book_id":1}]}}')
            elseif url:find("/api/reader/book/progress", 1, true) then
                cb('{"code":0,"data":[{"book_id":1,"item_id":12,"read_progress":2500,"index":1}]}')
            else
                cb('{"code":0,"data":{"content":"<p>正文</p>"}}')
            end
            return { cancel = function() end }
        end,
        post = function(url, body, opts, cb)
            requests[#requests + 1] = { method = "POST", url = url, body = body, opts = opts }
            cb('{"code":0,"data":{"detail_list":[{"book_id":1,"book_name":"测试书"}]}}')
            return { cancel = function() end }
        end,
    }
end

for _, key in ipairs({ "source.fanqie.client", "http.request", "json", "gettext", "l10n" }) do
    package.loaded[key] = nil
end
local Client = require("source.fanqie.client")
local client = Client:new{ cookies = { sessionid = "sid" } }

do
    Assert.is_true(client:configured())
    Assert.eq(Client.bookId("https://fanqienovel.com/page/123"), "123")
    Assert.eq(Client.bookId("https://fanqienovel.com/reader/456"), "456")
end

do
    local wire, err
    client:shelfSyncAsync(function(value, value_err) wire, err = value, value_err end)
    Assert.is_nil(err)
    Assert.eq(wire.data.detail_list[1].book_id, 1)
    Assert.eq(#requests, 3)
    Assert.matches(requests[1].url, "fanqienovel%.com/reading/bookapi/bookshelf/info")
    Assert.matches(requests[2].url, "fanqienovel%.com/api/reader/book/progress")
    Assert.matches(requests[3].url, "fanqienovel%.com/api/bookshelf/multidetail")
    Assert.eq(requests[1].opts.headers.Cookie, "sessionid=sid")
end

for _, key in ipairs({ "source.fanqie.client", "http.request", "json", "gettext", "l10n" }) do
    package.preload[key] = nil
    package.loaded[key] = nil
end
