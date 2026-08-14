--[[--
source.error 离线用例

@module tests.source.error_spec
--]]

local Assert = require("support.assert")
local SourceError = require("source.error")

do
    local e = SourceError.offline("net")
    Assert.eq(e.code, "offline")
    Assert.is_true(e.retryable)
end

do
    local e = SourceError.wrap("boom", "protocol")
    Assert.eq(e.code, "protocol")
    Assert.eq(e.message, "boom")
end

do
    local e = SourceError.wrap({ code = "unauthorized", message = "login", retryable = false })
    Assert.eq(e.code, "unauthorized")
end
