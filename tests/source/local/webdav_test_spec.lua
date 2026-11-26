--[[--
本地客户端的 WebDAV 传输：设置页改共享配置后，下一次请求用新地址，不沿用构造时的空地址。

@module tests.source.local.webdav_test_spec
--]]

local Assert = require("support.assert")

package.loaded["source.local.client"] = nil
local Client = require("source.local.client")

do
    local cfg = {}
    local client = Client.new(cfg)
    cfg.webdav_url = "http://dav.example:8088/"
    cfg.webdav_username = "moon"
    cfg.webdav_password = "pw"
    Assert.eq(client.dav:join("books", true), "http://dav.example:8088/books/")
    Assert.eq(client.dav.username, "moon")
    Assert.eq(client.dav.password, "pw")
end
