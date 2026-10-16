--[[--
features.remote.settings 离线测试：脱敏、白名单写入。

@module tests.features.remote.settings_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")

local store = {
    ai = { ai_endpoint = "", ai_api_key = "", ai_model = "" },
    moon = { base_url = "", token = "" },
    zlib = { email = "", password = "", base_url = nil },
    opds = {},
    copymanga = {},
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
        save = function(section, cfg)
            store[section] = cfg
        end,
        saveSource = function(id, cfg)
            store[id] = cfg
        end,
    }
end

local external = {}
package.preload["source.registry"] = function()
    return {
        list = function()
            local out = { { id = "local", name = "本地" } }
            for id, desc in pairs(external) do out[#out + 1] = { id = id, name = desc.name } end
            return out
        end,
        external = function(id) return external[id] end,
        invalidate = function() invalidated = invalidated + 1 end,
        notifyChanged = function()
            require("ui/uimanager"):broadcastEvent(require("ui/event"):new("SourceChanged"))
        end,
    }
end

local SettingsApi = require("features.remote.settings")

-- 初始快照：密钥脱敏
do
    store.ai.ai_endpoint = "https://api.example.com/v1"
    store.ai.ai_api_key = "sk-secret"
    store.ai.ai_model = "gpt-test"
    local snap = SettingsApi.snapshot()
    Assert.eq(snap.ai.ai_endpoint, "https://api.example.com/v1")
    Assert.eq(snap.ai.ai_api_key, SettingsApi.MASK)
    Assert.eq(snap.ai.ai_model, "gpt-test")

    -- 网页按 builtin 的字段声明建内置表单：顺序、类型、脱敏都由设备下发。
    local ids = {}
    for _idx, form in ipairs(snap.builtin) do ids[#ids + 1] = form.id end
    Assert.eq(table.concat(ids, ","), "ai,copymanga,moon,zlib,opds,local")
    local ai = snap.builtin[1]
    Assert.eq(ai.name, "AI 服务")
    Assert.eq(ai.fields[1].type, "url")
    Assert.eq(ai.fields[2].type, "password")
    Assert.eq(ai.fields[2].value, SettingsApi.MASK)
    Assert.eq(ai.fields[3].type, "text")
    Assert.eq(ai.fields[3].value, "gpt-test")
    Assert.eq(ai.fields[4].key, "ai_max_tokens")
    Assert.eq(ai.fields[4].type, "text")
    Assert.is_nil(ai.fields[1].normalize, "函数不下发")
    Assert.eq(snap.zlib.base_url, "", "nil 值下发空串")
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

-- zlib：换账号清会话，只换镜像保留会话；镜像留空落 nil（自动选择）。
do
    store.zlib = { email = "a@x", password = "pw", user_id = "1", user_key = "k", base_url = "https://m1" }
    SettingsApi.apply({ zlib = { base_url = " https://m2 " } })
    Assert.eq(store.zlib.base_url, "https://m2")
    Assert.eq(store.zlib.user_key, "k", "只换镜像不清会话")
    SettingsApi.apply({ zlib = { base_url = "", password = SettingsApi.MASK } })
    Assert.is_nil(store.zlib.base_url)
    Assert.eq(store.zlib.user_key, "k", "占位符密码不算换账号")
    SettingsApi.apply({ zlib = { password = "pw2" } })
    Assert.is_nil(store.zlib.user_id)
    Assert.is_nil(store.zlib.user_key)
end

-- 拷贝漫画：站点只修剪尾斜杠，密码原样保存，变更作废源实例。
do
    invalidated = 0
    SettingsApi.apply({ copymanga = { base_url = "https://copy.test//", username = " u ", password = " p " } })
    Assert.eq(store.copymanga.base_url, "https://copy.test")
    Assert.eq(store.copymanga.username, "u")
    Assert.eq(store.copymanga.password, " p ")
    Assert.eq(invalidated, 1)
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
    package.preload["http.cache"] = function()
        return { clear = function(s) cleared[#cleared + 1] = s end }
    end
    package.loaded["ui/uimanager"], package.loaded["ui/event"], package.loaded["http.cache"] = nil, nil, nil

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

-- 第三方源：设置模块声明的字段出现在快照（密钥脱敏），只写声明过的键，按字段规范化。
do
    Assert.len(SettingsApi.snapshot().external, 0, "没有声明表单的源不出现")
    store["ext.kav"] = { base_url = "http://kav", api_key = "secret", libraries = { ["1"] = true } }
    external["ext.kav"] = { name = "Kavita", setting = { remote = {
        { key = "base_url", label = "服务器地址", type = "url", placeholder = "http://",
            normalize = function(v) return (v:gsub("%s", ""):gsub("/+$", "")) end },
        { key = "api_key", label = "API Key", secret = true },
    } } }
    local form = SettingsApi.snapshot().external[1]
    Assert.eq(form.id, "ext.kav")
    Assert.eq(form.name, "Kavita")
    Assert.eq(form.fields[1].value, "http://kav")
    Assert.eq(form.fields[1].type, "url")
    Assert.eq(form.fields[2].value, SettingsApi.MASK)
    Assert.eq(form.fields[2].type, "password")
    Assert.is_nil(form.fields[1].normalize, "函数不下发")

    invalidated = 0
    local result = SettingsApi.apply({ external = { ["ext.kav"] = {
        base_url = " http://new/ ", api_key = SettingsApi.MASK, libraries = "hack",
    } } })
    Assert.is_true(result.changed)
    Assert.eq(invalidated, 1)
    Assert.eq(store["ext.kav"].base_url, "http://new")
    Assert.eq(store["ext.kav"].api_key, "secret", "占位符不改密钥")
    Assert.is_true(store["ext.kav"].libraries["1"], "没声明的键不碰")
    result = SettingsApi.apply({ external = { ["ext.kav"] = { api_key = " k2 " } } })
    Assert.eq(store["ext.kav"].api_key, "k2", "缺省规范化去首尾空白")
    result = SettingsApi.apply({ external = { ["ext.kav"] = { api_key = "k2" }, ["ext.none"] = { x = 1 } } })
    Assert.is_false(result.changed)
    Assert.eq(invalidated, 2)
end

for _, name in ipairs({
    "utils.settings", "source.registry", "features.remote.settings",
}) do
    package.preload[name] = nil
    package.loaded[name] = nil
end
