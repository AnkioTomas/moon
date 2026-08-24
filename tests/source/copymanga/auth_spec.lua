--[[--
source.copymanga.auth 离线用例

@module tests.source.copymanga.auth_spec
--]]

local Assert = require("support.assert")

local state = {
    cfg = {},
    saved = nil,
}

package.preload["utils.settings"] = function()
    return {
        getSource = function()
            return state.cfg
        end,
        saveSource = function(_id, c)
            state.saved = c
        end,
    }
end

for _, name in ipairs({ "source.copymanga.auth", "utils.settings" }) do
    package.loaded[name] = nil
end

local Auth = require("source.copymanga.auth")

do
    state.cfg = { api_host = "api.example.com" }
    Assert.eq(Auth.apiHost(), "api.example.com")
end

do
    state.cfg = {}
    Assert.eq(Auth.apiHost(), Auth.DEFAULT_API_HOST)
end

do
    state.cfg = { token = "abc" }
    Assert.is_true(Auth.hasSession())
    Assert.eq(Auth.token(), "abc")
end

do
    state.cfg = { token = "" }
    Assert.is_false(Auth.hasSession())
end

do
  local encoded = Auth.encodePassword("secret")
  Assert.is_true(type(encoded) == "string" and #encoded > 0)
end

do
    state.cfg = { username = "u1", token = "t1" }
    Auth.logout()
    Assert.eq(state.saved.token, "")
    Assert.eq(state.saved.username, "")
end
