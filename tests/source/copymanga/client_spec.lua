--[[--
拷贝漫画 App 客户端常量用例。

@module tests.source.copymanga.client_spec
--]]

local Assert = require("support.assert")
local Client = require("source.copymanga.client")

do
    Assert.eq(Client.normalizeBaseUrl(""), Client.DEFAULT_BASE_URL)
    Assert.eq(Client.normalizeBaseUrl("https://copy4000.com"), Client.DEFAULT_BASE_URL)
    Assert.eq(Client.normalizeBaseUrl("https://copy4000.com/"), Client.DEFAULT_BASE_URL)
    Assert.eq(Client.normalizeBaseUrl("https://api.example.com/"), "https://api.example.com")
end

do
    local headers = Client.headers("abc")
    Assert.eq(headers["User-Agent"], "COPY/3.0.0")
    Assert.eq(headers.platform, "1")
    Assert.eq(headers.Authorization, "Token abc")
    Assert.is_nil(Client.headers("").Authorization)
end

do
    local client = Client:new({})
    Assert.eq(client.base_url, Client.DEFAULT_BASE_URL)
    Assert.is_true(client:configured())
end
