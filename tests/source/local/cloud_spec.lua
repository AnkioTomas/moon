--[[-- 本地书库网盘选择：旧 WebDAV 配置不变，Google Drive 走同一套文件接口。已下线的 dropbox 关闭，不改走 WebDAV。 --]]

local Assert = require("support.assert")

local Client = require("source.local.client")

-- 没写 cloud、只填了地址：仍是 WebDAV。
do
    local cfg = { webdav_url = "https://dav.example/dav/", webdav_username = "u" }
    local client = Client.new(cfg)
    Assert.eq(client:cloudKind(), "webdav")
    Assert.is_true(client:hasCloud())
    Assert.is_true(client:isWebdav())
    Assert.eq(client.dav.url, "https://dav.example/dav")
end

-- off 关掉网盘，即使地址还在。
do
    local client = Client.new({ cloud = "off", webdav_url = "https://dav.example" })
    Assert.is_nil(client:cloudKind())
    Assert.is_false(client:hasCloud())
    Assert.is_false(client:configured())
end

-- Google Drive 凭据变了就换客户端。写过 dropbox 的旧配置关掉，旁边的 WebDAV 地址不接管。
do
    local cfg = { cloud = "gdrive", gdrive_token = "refresh", gdrive_client = "id:secret" }
    local client = Client.new(cfg)
    Assert.eq(client:cloudKind(), "gdrive")
    Assert.eq(client.dav.kind, "gdrive")
    local first = client.dav
    Assert.eq(client.dav, first)
    cfg.gdrive_token = "other"
    Assert.is_true(client.dav ~= first)
    Assert.eq(client.dav.kind, "gdrive")

    local drive = Client.new({ cloud = "GDrive", gdrive_token = "r", gdrive_client = "id:secret" })
    Assert.eq(drive:cloudKind(), "gdrive")

    local retired = Client.new({ cloud = "dropbox", dropbox_token = "t", webdav_url = "https://dav.example" })
    Assert.is_nil(retired:cloudKind())
    Assert.is_false(retired:hasCloud())
end

-- 凭据不齐时 validatePath 直接失败，不发请求。
do
    local ok, err = Client.new({ cloud = "gdrive", gdrive_token = "t", gdrive_client = "nosecret" }):validatePath()
    Assert.is_false(ok)
    Assert.eq(err, "Google 客户端格式应为 ID:密钥")

    ok = Client.new({ cloud = "gdrive", gdrive_token = "t", gdrive_client = "id:secret" }):validatePath()
    Assert.is_true(ok)
end

return true
