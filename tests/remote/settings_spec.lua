--[[--
remote.settings 离线测试：脱敏、白名单写入。

@module tests.remote.settings_spec
--]]

local Assert = require("support.assert")

local store = {
    ai = { ai_endpoint = "", ai_api_key = "", ai_model = "" },
    moon = { base_url = "", token = "" },
    zlib = { email = "", password = "", base_url = nil },
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

    result = SettingsApi.apply({ ai = {}, moon = {}, zlib = {} })
    Assert.is_false(result.changed)
end

for _, name in ipairs({
    "utils.settings", "source.registry", "remote.settings",
}) do
    package.preload[name] = nil
    package.loaded[name] = nil
end
