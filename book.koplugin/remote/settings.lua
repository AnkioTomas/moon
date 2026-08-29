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

---@param value string|nil
---@param secret boolean
---@return string
local function maskValue(value, secret)
    if value == nil or value == "" then
        return ""
    end
    if secret then
        return SettingsApi.MASK
    end
    return tostring(value)
end

---@param value any
---@return boolean
local function unchangedSecret(value)
    return value == SettingsApi.MASK or value == "******"
end

---@param cfg table
---@param key string
---@param incoming any
---@param normalize fun(string): string
---@return boolean changed
local function applyField(cfg, key, incoming, normalize)
    -- /api/settings is PATCH-like: omitting a key must not erase its saved value.
    if incoming == nil then
        return false
    end
    if SECRET_KEYS[key] and unchangedSecret(incoming) then
        return false
    end
    local next = normalize(tostring(incoming))
    if cfg[key] ~= next then
        cfg[key] = next
        return true
    end
    return false
end

---@param value any
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
    local zlib = Settings.getSource("zlib")
    return {
        ai = {
            ai_endpoint = asStr(ai.ai_endpoint),
            ai_api_key = maskValue(ai.ai_api_key, true),
            ai_model = asStr(ai.ai_model),
        },
        moon = {
            base_url = asStr(moon.base_url),
            token = maskValue(moon.token, true),
        },
        zlib = {
            email = asStr(zlib.email),
            password = maskValue(zlib.password, true),
            base_url = asStr(zlib.base_url),
        },
    }
end

---@param group table|nil
---@return boolean
local function hasGroup(group)
    return type(group) == "table"
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

    if hasGroup(payload.ai) then
        local cfg = Settings.get("ai")
        local g = payload.ai
        local ai_changed = false
        if applyField(cfg, "ai_endpoint", g.ai_endpoint, function(v)
            return Text.rtrimSlashes(Text.trim(v))
        end) then
            ai_changed = true
        end
        if applyField(cfg, "ai_api_key", g.ai_api_key, Text.trim) then
            ai_changed = true
        end
        if applyField(cfg, "ai_model", g.ai_model, Text.trim) then
            ai_changed = true
        end
        if ai_changed then
            Settings.saveSection("ai", cfg)
            changed = true
        end
    end

    if hasGroup(payload.moon) then
        local cfg = Settings.getSource("moon")
        local g = payload.moon
        local moon_changed = false
        if applyField(cfg, "base_url", g.base_url, Text.stripWhitespace) then
            moon_changed = true
        end
        if applyField(cfg, "token", g.token, Text.stripWhitespace) then
            moon_changed = true
        end
        if moon_changed then
            Settings.saveSource("moon", cfg)
            require("source.registry").invalidate()
            changed = true
        end
    end

    if hasGroup(payload.zlib) then
        local cfg = Settings.getSource("zlib")
        local g = payload.zlib
        local zlib_changed = false
        if applyField(cfg, "email", g.email, Text.trim) then
            cfg.user_id, cfg.user_key = nil, nil
            zlib_changed = true
        end
        if applyField(cfg, "password", g.password, function(v) return v or "" end) then
            cfg.user_id, cfg.user_key = nil, nil
            zlib_changed = true
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

    return { ok = true, changed = changed, settings = SettingsApi.snapshot() }
end

return SettingsApi
