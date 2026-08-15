--[[-- Z-Library client 鉴权与会话离线用例。 @module tests.zlib.client_spec --]]

local Assert = require("support.assert")

local original_preload = {}
for _, name in ipairs({ "json", "http.request", "utils.settings" }) do
    original_preload[name] = package.preload[name]
end
local captured = {}
local response = { code = 200, body = '{"success":1}' }
local response_data = { success = 1 }
package.preload["json"] = function()
    return { decode = function() return response_data end }
end
package.preload["http.request"] = function()
    return {
        ok = function(code) return tonumber(code) >= 200 and tonumber(code) < 300 end,
        header = function(res, name) return res and res.headers and res.headers[name] end,
        request = function(opts, cb)
            captured[#captured + 1] = opts
            cb(response)
            return { cancel = function() end }
        end,
        download = function(opts, _dest, cb)
            captured[#captured + 1] = opts
            cb(true, nil, { code = 200, headers = { ["Content-Type"] = "application/epub+zip" } })
            return { cancel = function() end }
        end,
    }
end

local saved
package.preload["utils.settings"] = function()
    return { saveSource = function(id, cfg) saved = { id = id, cfg = cfg } end }
end
package.loaded["http.request"] = nil
package.loaded["utils.settings"] = nil
package.loaded["zlib.client"] = nil

local Client = require("zlib.client")
local cfg = { email = "me@example.com", password = "secret" }
local client = Client.new(cfg)

local ok
client:pingAsync(function(v) ok = v end)
Assert.is_true(ok)
Assert.eq(captured[1].url, "https://zh.iread.ink/eapi/info/ok")
Assert.eq(captured[1].auth_username, "iread")
Assert.eq(captured[1].auth_password, "DGvG2h3JMOvEoS")

response = { code = 200, body = '{"success":1,"pagination":{"total_items":5},"books":[]}' }
response_data = { success = 1, pagination = { total_items = 5 }, books = {} }
client:searchAsync("Lua 书", 2, 12, function(data) Assert.eq(data.pagination.total_items, 5) end)
Assert.eq(captured[2].method, "POST")
Assert.matches(captured[2].body, "message=Lua%%20%%E4%%B9%%A6")
Assert.matches(captured[2].body, "page=2")
Assert.matches(captured[2].body, "limit=12")

response = { code = 200, body = '{"success":1,"user":{"id":42,"remix_userkey":"key42"}}' }
response_data = { success = 1, user = { id = 42, remix_userkey = "key42" } }
client:loginAsync(function(v) ok = v end)
Assert.is_true(ok)
Assert.eq(client.user_id, "42")
Assert.eq(client.user_key, "key42")
Assert.eq(saved.id, "zlib")
Assert.eq(saved.cfg.user_key, "key42")

response = { code = 200, body = '{"success":1,"file":{"downloadLink":"https://cdn.example/book.epub"}}' }
response_data = { success = 1, file = { downloadLink = "https://cdn.example/book.epub" } }
local link
client:downloadLinkAsync("1", "abc", function(v) link = v end)
Assert.eq(link, "https://cdn.example/book.epub")
Assert.matches(captured[4].headers.Cookie, "remix_userid=42")

for _, name in ipairs({ "json", "http.request", "utils.settings" }) do
    package.preload[name] = original_preload[name]
    package.loaded[name] = nil
end
package.loaded["zlib.client"] = nil
