--[[--
remote.settings 离线测试：脱敏、白名单写入。

@module tests.remote.settings_spec
--]]

local Assert = require("support.assert")

local store = {
    ai = { ai_endpoint = "", ai_api_key = "", ai_model = "" },
    moon = { base_url = "", token = "" },
    zlib = { email = "", password = "", base_url = nil },
    opds = {},
    ["local"] = { path = "/mnt/books" },
}
local invalidated = 0

package.preload["utils.settings"] = function()
    return {
        get = function(section)
            return store[section]
        end,
        getSource = function(id)
            return store[id]
        end,
        saveSection = function(section, cfg)
            store[section] = cfg
        end,
        saveSource = function(id, cfg)
            store[id] = cfg
        end,
    }
end

package.preload["source.registry"] = function()
    return { invalidate = function() invalidated = invalidated + 1 end }
end

local SettingsApi = require("remote.settings")

-- 初始快照：密钥脱敏
do
    store.ai.ai_endpoint = "https://api.example.com/v1"
    store.ai.ai_api_key = "sk-secret"
    store.ai.ai_model = "gpt-test"
    local snap = SettingsApi.snapshot()
    Assert.eq(snap.ai.ai_endpoint, "https://api.example.com/v1")
    Assert.eq(snap.ai.ai_api_key, SettingsApi.MASK)
    Assert.eq(snap.ai.ai_model, "gpt-test")
end

-- ****** 占位符不覆盖密钥
do
    local result = SettingsApi.apply({
        ai = {
            ai_endpoint = "https://new.example.com/v1",
            ai_api_key = SettingsApi.MASK,
            ai_model = "new-model",
        },
    })
    Assert.is_true(result.ok)
    Assert.eq(store.ai.ai_endpoint, "https://new.example.com/v1")
    Assert.eq(store.ai.ai_api_key, "sk-secret")
    Assert.eq(store.ai.ai_model, "new-model")
end

-- Moon 变更触发 registry.invalidate
do
    invalidated = 0
    SettingsApi.apply({ moon = { base_url = "https://moon.test", token = "bk" } })
    Assert.eq(invalidated, 1)
    Assert.eq(store.moon.base_url, "https://moon.test")
end

-- 远程 API 是部分更新：未提交的字段（尤其密钥）必须原样保留。
do
    store.ai.ai_endpoint = "https://keep.example/v1"
    store.ai.ai_api_key = "keep-ai-key"
    store.ai.ai_model = "old-model"
    local result = SettingsApi.apply({ ai = { ai_model = "partial-model" } })
    Assert.is_true(result.changed)
    Assert.eq(store.ai.ai_endpoint, "https://keep.example/v1")
    Assert.eq(store.ai.ai_api_key, "keep-ai-key")
    Assert.eq(store.ai.ai_model, "partial-model")

    store.moon.base_url, store.moon.token = "https://keep.moon", "keep-token"
    SettingsApi.apply({ moon = { base_url = "https://new.moon" } })
    Assert.eq(store.moon.token, "keep-token")

    store.zlib.email, store.zlib.password, store.zlib.base_url = "old@example.com", "keep-password", "https://keep.zlib"
    SettingsApi.apply({ zlib = { email = "new@example.com" } })
    Assert.eq(store.zlib.password, "keep-password")
    Assert.eq(store.zlib.base_url, "https://keep.zlib")

    result = SettingsApi.apply({ ai = {}, moon = {}, zlib = {}, ["local"] = {} })
    Assert.is_false(result.changed)
end

-- OPDS：地址补协议、密码脱敏、占位符与缺省键不覆盖；有变化才广播重算底栏。
do
    local broadcasts, cleared = 0, {}
    package.preload["ui/uimanager"] = function()
        return { broadcastEvent = function(_, ev) if ev.name == "SourceChanged" then broadcasts = broadcasts + 1 end end }
    end
    package.preload["ui/event"] = function()
        return { new = function(_, name) return { name = name } end }
    end
    package.preload["http.request"] = function()
        return { clearCache = function(s) cleared[#cleared + 1] = s end }
    end
    package.loaded["ui/uimanager"], package.loaded["ui/event"], package.loaded["http.request"] = nil, nil, nil

    local result = SettingsApi.apply({ opds = { url = " nas:8083/opds ", username = " u ", password = "pw" } })
    Assert.is_true(result.changed)
    Assert.eq(store.opds.url, "http://nas:8083/opds")
    Assert.eq(store.opds.username, "u")
    Assert.eq(store.opds.password, "pw")
    Assert.eq(broadcasts, 1)
    Assert.eq(cleared[1], "http://nas:8083")
    Assert.eq(result.settings.opds.password, SettingsApi.MASK)
    Assert.eq(result.settings.opds.url, "http://nas:8083/opds")

    result = SettingsApi.apply({ opds = { url = "http://nas:8083/opds", password = SettingsApi.MASK } })
    Assert.is_false(result.changed)
    Assert.eq(store.opds.password, "pw")
    Assert.eq(store.opds.username, "u")
    Assert.eq(broadcasts, 1)

    -- 清空地址即关闭 OPDS：同样要广播让页签消失。
    result = SettingsApi.apply({ opds = { url = "" } })
    Assert.is_true(result.changed)
    Assert.is_nil(store.opds.url)
    Assert.eq(broadcasts, 2)

    package.preload["ui/uimanager"], package.preload["ui/event"], package.preload["http.request"] = nil, nil, nil
    package.loaded["ui/uimanager"], package.loaded["ui/event"], package.loaded["http.request"] = nil, nil, nil
end

-- 本地源 WebDAV：trim 落盘、密码脱敏、占位符不覆盖、不碰 path。
do
    invalidated = 0
    local result = SettingsApi.apply({ ["local"] = {
        webdav_url = " https://dav.test/dav ",
        webdav_username = "u",
        webdav_password = "dav-secret",
        webdav_path = "/books",
    } })
    Assert.is_true(result.changed)
    Assert.eq(invalidated, 1)
    local cfg = store["local"]
    Assert.eq(cfg.webdav_url, "https://dav.test/dav")
    Assert.eq(cfg.webdav_password, "dav-secret")
    Assert.eq(cfg.path, "/mnt/books")
    Assert.eq(result.settings["local"].webdav_password, SettingsApi.MASK)
    Assert.eq(result.settings["local"].webdav_path, "/books")

    result = SettingsApi.apply({ ["local"] = { webdav_password = SettingsApi.MASK, webdav_path = "" } })
    Assert.eq(cfg.webdav_password, "dav-secret")
    Assert.eq(cfg.webdav_path, "")
    Assert.eq(invalidated, 2)

    result = SettingsApi.apply({ ["local"] = { webdav_url = "https://dav.test/dav" } })
    Assert.is_false(result.changed)
    Assert.eq(invalidated, 2)
end

for _, name in ipairs({
    "utils.settings", "source.registry", "remote.settings",
}) do
    package.preload[name] = nil
    package.loaded[name] = nil
end
