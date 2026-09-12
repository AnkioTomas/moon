--[[--
番茄小说扫码 Cookie 原语离线用例。

@module tests.source.fanqie.auth_spec
--]]

local Assert = require("support.assert")

local settings = { cookies = {} }
package.preload["utils.settings"] = function()
    return {
        getSource = function() return settings end,
        saveSource = function(_, value) settings = value end,
    }
end
package.preload["http.request"] = function()
    return {}
end

package.loaded["source.fanqie.auth"] = nil
package.loaded["utils.settings"] = nil
package.loaded["http.request"] = nil
local Auth = require("source.fanqie.auth")

do
    Assert.eq(Auth.cookieHeader({ cookies = { z = "3", a = "1" } }), "a=1; z=3")
    Assert.is_true(Auth.hasSession({ cookies = { sessionid = "session" } }))
    Assert.is_false(Auth.hasSession({ cookies = { passport_csrf_token = "csrf" } }))
end

do
    local cookies = Auth.mergeSetCookie({}, "sessionid=abc; Path=/, passport_csrf_token=csrf; Path=/")
    Assert.eq(cookies.sessionid, "abc")
    Assert.eq(cookies.passport_csrf_token, "csrf")
    Auth.saveCookies(cookies)
    Assert.eq(settings.cookies.sessionid, "abc")
    Auth.clearSession()
    Assert.is_nil(settings.cookies.sessionid)
end

for _, key in ipairs({ "utils.settings", "http.request", "source.fanqie.auth" }) do
    package.preload[key] = nil
    package.loaded[key] = nil
end
