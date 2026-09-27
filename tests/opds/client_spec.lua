--[[-- OPDS client：凭据只发同源、请求参数。 @module tests.opds.client_spec --]]

local Assert = require("support.assert")

local got
package.preload["http.request"] = function()
    return {
        get = function(url, opts, cb) got = { url = url, opts = opts }; cb("body") end,
        download = function(opts, dest, cb) got = { opts = opts, dest = dest }; cb(true) end,
    }
end
package.loaded["http.request"] = nil
package.loaded["opds.client"] = nil
local Client = require("opds.client")

local c = Client.new({ url = " http://nas:8083/opds ", username = "u", password = "p" })
Assert.is_true(c:configured())
Assert.eq(c:rootUrl(), "http://nas:8083/opds")
Assert.eq(c:coverHeaders("http://nas:8083/cover/1").Authorization, "Basic dTpw")
Assert.is_nil(c:coverHeaders("http://nas:9999/cover/1"))
Assert.is_nil(c:coverHeaders("https://img.example/c.jpg"))
Assert.is_nil(c:coverHeaders(nil))
Assert.is_nil(Client.new({ url = "http://nas:8083/opds" }):coverHeaders("http://nas:8083/cover/1"))
Assert.is_false(Client.new({}):configured())
Assert.is_false(Client.new({ url = "  " }):configured())

c:getAsync("http://nas:8083/opds/new", function() end)
Assert.eq(got.url, "http://nas:8083/opds/new")
Assert.eq(got.opts.user, "u")
Assert.eq(got.opts.password, "p")
Assert.is_true(got.opts.cache_ttl > 0)
Assert.matches(got.opts.accept, "application/atom%+xml")

c:downloadAsync("http://nas:8083/dl/1", "/tmp/x.epub", nil, function() end)
Assert.eq(got.dest, "/tmp/x.epub")
Assert.eq(got.opts.auth_username, "u")
Assert.is_true(got.opts.allow_redirects)

package.preload["http.request"] = nil
package.loaded["http.request"] = nil
package.loaded["opds.client"] = nil
