--[[--
remote.settings 离线测试：脱敏、白名单写入、OPML 合并。

@module tests.remote.settings_spec
--]]

local Assert = require("support.assert")

local store = {
    ai = { ai_endpoint = "", ai_api_key = "", ai_model = "" },
    moon = { base_url = "", token = "" },
    webdav = { url = "", username = "", password = "" },
    zlib = { email = "", password = "", base_url = nil },
    rss = { feeds = {} },
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

-- POST：更新 endpoint，掩码密钥保持不变
do
    invalidated = 0
    local result = SettingsApi.apply({
        ai = {
            ai_endpoint = "https://api.new.com/v1/",
            ai_api_key = SettingsApi.MASK,
            ai_model = "gpt-test",
        },
    })
    Assert.is_true(result.ok)
    Assert.is_true(result.changed)
    Assert.eq(store.ai.ai_endpoint, "https://api.new.com/v1")
    Assert.eq(store.ai.ai_api_key, "sk-secret", "掩码占位不得覆盖原密钥")
    Assert.eq(result.settings.ai.ai_api_key, SettingsApi.MASK)
end

-- Moon / WebDAV 写入触发 registry.invalidate
do
    invalidated = 0
    local result = SettingsApi.apply({
        moon = { base_url = "https://moon.test", token = "bk_abc" },
        webdav = { url = "https://dav.test/", username = "u", password = "p" },
    })
    Assert.is_true(result.ok)
    Assert.eq(store.moon.base_url, "https://moon.test")
    Assert.eq(store.webdav.password, "p")
    Assert.eq(invalidated, 2)
end

-- Z-Library：改邮箱清会话字段
do
    store.zlib.user_id = "uid"
    store.zlib.user_key = "key"
    SettingsApi.apply({ zlib = { email = "a@b.com", password = SettingsApi.MASK, base_url = "" } })
    Assert.eq(store.zlib.email, "a@b.com")
    Assert.is_nil(store.zlib.user_id)
    Assert.is_nil(store.zlib.user_key)
    Assert.is_nil(store.zlib.base_url)
end

-- RSS：整表替换 + URL 规范化
do
    invalidated = 0
    SettingsApi.apply({
        rss = {
            feeds = {
                { url = "example.com/feed.xml", title = "Demo" },
                { url = "https://example.com/feed.xml", title = "Dup" },
            },
        },
    })
    Assert.eq(#store.rss.feeds, 1)
    Assert.eq(store.rss.feeds[1].url, "https://example.com/feed.xml")
    Assert.eq(store.rss.feeds[1].title, "Demo")
    Assert.eq(invalidated, 1)
end

-- OPML：合并去重
do
    store.rss.feeds = {
        { url = "https://keep.test/feed", title = "Keep" },
    }
    local result = SettingsApi.importOpml([[
<?xml version="1.0"?>
<opml><body>
<outline text="New" xmlUrl="https://new.test/rss"/>
<outline text="Dup" xmlUrl="https://keep.test/feed"/>
</body></opml>
]])
    Assert.is_true(result.ok)
    Assert.eq(result.added, 1)
    Assert.eq(#store.rss.feeds, 2)
end

-- 非法 JSON 载荷
do
    local result, err = SettingsApi.apply("nope")
    Assert.is_nil(result)
    Assert.eq(err, "invalid json")
end
