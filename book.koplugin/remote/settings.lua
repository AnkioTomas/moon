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
    if SECRET_KEYS[key] and unchangedSecret(incoming) then
        return false
    end
    local next = normalize(tostring(incoming or ""))
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
    local webdav = Settings.getSource("webdav")
    local zlib = Settings.getSource("zlib")
    local rss = Settings.getSource("rss")
    local feeds = type(rss.feeds) == "table" and rss.feeds or {}
    local out_feeds = {}
    for i, feed in ipairs(feeds) do
        out_feeds[i] = {
            url = asStr(feed.url),
            title = asStr(feed.title),
        }
    end
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
        webdav = {
            url = asStr(webdav.url),
            username = asStr(webdav.username),
            password = maskValue(webdav.password, true),
        },
        zlib = {
            email = asStr(zlib.email),
            password = maskValue(zlib.password, true),
            base_url = asStr(zlib.base_url),
        },
        rss = {
            feeds = out_feeds,
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

    if hasGroup(payload.webdav) then
        local cfg = Settings.getSource("webdav")
        local g = payload.webdav
        local webdav_changed = false
        if applyField(cfg, "url", g.url, Text.stripWhitespace) then
            webdav_changed = true
        end
        if applyField(cfg, "username", g.username, Text.stripWhitespace) then
            webdav_changed = true
        end
        if applyField(cfg, "password", g.password, function(v) return v or "" end) then
            webdav_changed = true
        end
        if webdav_changed then
            Settings.saveSource("webdav", cfg)
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
        local base = Text.trim(g.base_url or "")
        local next_base = base ~= "" and base or nil
        if cfg.base_url ~= next_base then
            cfg.base_url = next_base
            zlib_changed = true
        end
        if zlib_changed then
            Settings.saveSource("zlib", cfg)
            changed = true
        end
    end

    if hasGroup(payload.rss) and type(payload.rss.feeds) == "table" then
        local Parser = require("source.rss.parser")
        local cfg = Settings.getSource("rss")
        local list = {}
        local seen = {}
        for _, feed in ipairs(payload.rss.feeds) do
            if type(feed) == "table" then
                local url = Parser.normalizeUrl(feed.url)
                if url and not seen[url] then
                    seen[url] = true
                    list[#list + 1] = {
                        url = url,
                        title = Text.trim(feed.title),
                    }
                end
            end
        end
        cfg.feeds = list
        Settings.saveSource("rss", cfg)
        require("source.registry").invalidate()
        changed = true
    end

    return { ok = true, changed = changed, settings = SettingsApi.snapshot() }
end

---@param content string
---@return table|nil result
---@return string|nil err
function SettingsApi.importOpml(content)
    if type(content) ~= "string" or content == "" then
        return nil, "empty opml"
    end
    local OPML = require("source.rss.opml")
    local Parser = require("source.rss.parser")
    local imported = OPML.parse(content)
    if not imported then
        return nil, "invalid opml"
    end
    local Settings = require("utils.settings")
    local cfg = Settings.getSource("rss")
    local list = type(cfg.feeds) == "table" and cfg.feeds or {}
    local seen = {}
    for _, feed in ipairs(list) do
        local url = Parser.normalizeUrl(feed.url)
        if url then
            seen[url] = true
        end
    end
    local added = 0
    for _, feed in ipairs(imported) do
        local url = Parser.normalizeUrl(feed.url)
        if url and not seen[url] then
            seen[url] = true
            list[#list + 1] = {
                url = url,
                title = Text.trim(feed.title),
            }
            added = added + 1
        end
    end
    cfg.feeds = list
    Settings.saveSource("rss", cfg)
    require("source.registry").invalidate()
    return {
        ok = true,
        added = added,
        settings = SettingsApi.snapshot(),
    }
end

return SettingsApi
