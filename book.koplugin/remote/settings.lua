--[[--
远程配置：白名单读写（连接类设置在浏览器填写）。

GET 脱敏密钥；POST 里保留占位符 "******" 表示不修改该字段。
全部经 utils.settings 落盘，副作用（registry.invalidate、zlib 清会话）与设备设置一致。

@module koplugin.book.remote.settings
--]]

local Text = require("utils.text")

local SettingsApi = {}

SettingsApi.MASK = "******"
SettingsApi.BODY_LIMIT = 256 * 1024

---@type table<string, boolean>
local SECRET_KEYS = {
    ai_api_key = true,
    token = true,
    password = true,
}

--- 密钥脱敏：空值回空串，否则一律占位符。
---@param value string|nil
---@return string
local function maskValue(value)
    if value == nil or value == "" then
        return ""
    end
    return SettingsApi.MASK
end

---@param cfg table
---@param key string
---@param normalize fun(string): string
---@return boolean changed
local function applyField(cfg, key, incoming, normalize)
    -- /api/settings is PATCH-like: omitting a key must not erase its saved value.
    if incoming == nil then
        return false
    end
    if SECRET_KEYS[key] and incoming == SettingsApi.MASK then
        return false
    end
    local next = normalize(tostring(incoming))
    if cfg[key] ~= next then
        cfg[key] = next
        return true
    end
    return false
end

---@return string
local function asStr(value)
    if value == nil then
        return ""
    end
    return tostring(value)
end

---@return table
function SettingsApi.snapshot()
    local Settings = require("utils.settings")
    local ai = Settings.get("ai")
    local moon = Settings.getSource("moon")
    local copymanga = Settings.getSource("copymanga") or {}
    local zlib = Settings.getSource("zlib")
    return {
        ai = {
            ai_endpoint = asStr(ai.ai_endpoint),
            ai_api_key = maskValue(ai.ai_api_key),
            ai_model = asStr(ai.ai_model),
        },
        moon = {
            base_url = asStr(moon.base_url),
            token = maskValue(moon.token),
        },
        copymanga = {
            base_url = asStr(copymanga.base_url),
            username = asStr(copymanga.username),
            password = maskValue(copymanga.password),
        },
        zlib = {
            email = asStr(zlib.email),
            password = maskValue(zlib.password),
            base_url = asStr(zlib.base_url),
        },
    }
end

---@param payload table
---@return table|nil result
---@return string|nil err
function SettingsApi.apply(payload)
    if type(payload) ~= "table" then
        return nil, "invalid json"
    end
    local Settings = require("utils.settings")
    local changed = false

    if type(payload.ai) == "table" then
        local cfg = Settings.get("ai")
        local g = payload.ai
        local ai_changed = applyField(cfg, "ai_endpoint", g.ai_endpoint, function(v)
            return Text.rtrimSlashes(Text.trim(v))
        end)
        ai_changed = applyField(cfg, "ai_api_key", g.ai_api_key, Text.trim) or ai_changed
        ai_changed = applyField(cfg, "ai_model", g.ai_model, Text.trim) or ai_changed
        if ai_changed then
            Settings.saveSection("ai", cfg)
            changed = true
        end
    end

    if type(payload.moon) == "table" then
        local cfg = Settings.getSource("moon")
        local g = payload.moon
        local moon_changed = applyField(cfg, "base_url", g.base_url, Text.stripWhitespace)
        moon_changed = applyField(cfg, "token", g.token, Text.stripWhitespace) or moon_changed
        if moon_changed then
            Settings.saveSource("moon", cfg)
            require("source.registry").invalidate()
            changed = true
        end
    end

    if type(payload.zlib) == "table" then
        local cfg = Settings.getSource("zlib")
        local g = payload.zlib
        local zlib_changed = applyField(cfg, "email", g.email, Text.trim)
        zlib_changed = applyField(cfg, "password", g.password, tostring) or zlib_changed
        if zlib_changed then
            cfg.user_id, cfg.user_key = nil, nil
        end
        if g.base_url ~= nil then
            local base = Text.trim(tostring(g.base_url))
            local next_base = base ~= "" and base or nil
            if cfg.base_url ~= next_base then
                cfg.base_url = next_base
                zlib_changed = true
            end
        end
        if zlib_changed then
            Settings.saveSource("zlib", cfg)
            changed = true
        end
    end

    if type(payload.copymanga) == "table" then
        local cfg = Settings.getSource("copymanga") or {}
        local g = payload.copymanga
        local changed_group = applyField(cfg, "base_url", g.base_url, Text.rtrimSlashes)
        changed_group = applyField(cfg, "username", g.username, Text.trim) or changed_group
        changed_group = applyField(cfg, "password", g.password, tostring) or changed_group
        if changed_group then
            -- Credentials and endpoint affect the active client/session.
            Settings.saveSource("copymanga", cfg)
            require("source.registry").invalidate()
            changed = true
        end
    end

    return { ok = true, changed = changed, settings = SettingsApi.snapshot() }
end

return SettingsApi
