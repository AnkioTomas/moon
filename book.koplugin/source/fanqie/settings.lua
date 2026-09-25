--[[--
番茄源配置：落在 utils.settings.getSource("fanqie")。

@module koplugin.book.source.fanqie.settings
--]]

local SOURCE_ID = "fanqie"

---@class FanqieSettings
---@field cfg table
---@field get fun(self: FanqieSettings, key: string, default: any): any
---@field set fun(self: FanqieSettings, key: string, value: any)
---@field flush fun(self: FanqieSettings)
---@field is_cookie_configured fun(self: FanqieSettings): boolean

local Settings = {}
Settings.__index = Settings

---@return FanqieSettings
function Settings:new()
    local cfg = require("utils.settings").getSource(SOURCE_ID)
    return setmetatable({ cfg = cfg }, self)
end

---@param key string
function Settings:get(key, default)
    local value = self.cfg[key]
    if value == nil then return default end
    return value
end

---@param key string
function Settings:set(key, value)
    self.cfg[key] = value
end

function Settings:flush()
    require("utils.settings").saveSource(SOURCE_ID, self.cfg)
end

---@return boolean
function Settings:is_cookie_configured()
    -- 书架接口要 HttpOnly 会话 cookie；只有 novel_web_id 等可见 cookie 会返回 101119。
    local cookies = self.cfg.cookies
    return type(cookies) == "table"
        and type(cookies.sessionid) == "string"
        and cookies.sessionid ~= ""
end

return Settings
