--[[--
月读同步的连通性测试：地址检查之后才建 WebDAV 客户端。

@module tests.moon_sync.probe_spec
--]]

local Assert = require("support.assert")

local moon = {
    webdav_url = "",
    webdav_username = "user",
    webdav_password = "secret",
    webdav_path = "Books",
}
local probed

package.preload["utils.settings"] = function()
    return { get = function() return moon end }
end
package.preload["http.webdav"] = function()
    return {
        new = function(cfg)
            return {
                probeAsync = function(_, path, cb)
                    probed = { cfg = cfg, path = path }
                    cb(true)
                    return { cancel = function() end }
                end,
            }
        end,
    }
end
package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, text) return text end })
end

for _idx, name in ipairs({ "utils.settings", "http.webdav", "gettext", "moon_sync" }) do
    package.loaded[name] = nil
end

local MoonSync = require("moon_sync")

do
    local ok, err
    MoonSync.testAsync(function(v, e) ok, err = v, e end)
    Assert.is_false(ok)
    Assert.eq(err, "未配置 WebDAV 地址")
    Assert.is_nil(probed, "没地址不建客户端")
end

do
    moon.webdav_url = "dav.example"
    local ok, err
    MoonSync.testAsync(function(v, e) ok, err = v, e end)
    Assert.is_false(ok)
    Assert.eq(err, "WebDAV 地址必须以 http:// 或 https:// 开头")
    Assert.is_nil(probed)
end

do
    moon.webdav_url = " https://dav.example/dav "
    local ok, err
    MoonSync.testAsync(function(v, e) ok, err = v, e end)
    Assert.is_true(ok)
    Assert.is_nil(err)
    Assert.eq(probed.cfg.url, "https://dav.example/dav")
    Assert.eq(probed.cfg.username, "user")
    Assert.eq(probed.cfg.password, "secret")
    Assert.eq(probed.path, "Books")
end

do
    moon.webdav_path = ""
    MoonSync.testAsync(function() end)
    Assert.eq(probed.path, "Apps/Books")
end
