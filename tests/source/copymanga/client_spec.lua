--[[--
source.copymanga.client 离线用例

@module tests.source.copymanga.client_spec
--]]

local Assert = require("support.assert")

package.preload["source.copymanga.auth"] = function()
    return {
        DEFAULT_API_HOST = "api.copy4000.com",
        apiHost = function() return "api.copy4000.com" end,
        hasSession = function() return false end,
        headers = function() return {} end,
    }
end

for _, name in ipairs({ "source.copymanga.client", "source.copymanga.auth" }) do
    package.loaded[name] = nil
end

local Client = require("source.copymanga.client")

do
    local client = Client:new()
    Assert.is_true(client:configured())
end
