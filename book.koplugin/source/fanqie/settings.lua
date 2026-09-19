--[[--
番茄源配置：落在 utils.settings.getSource("fanqie")。

@module koplugin.book.source.fanqie.settings
--]]

local SOURCE_ID = "fanqie"

local Settings = {}
Settings.__index = Settings

---@return FanqieSettings
function Settings:new()
    local cfg = require("utils.settings").getSource(SOURCE_ID)
    return setmetatable({ cfg = cfg }, self)
end

---@param key string
---@param default any
---@return any
function Settings:get(key, default)
    local value = self.cfg[key]
    if value == nil then return default end
    return value
end

---@param key string
---@param value any
function Settings:set(key, value)
    self.cfg[key] = value
end

function Settings:flush()
    require("utils.settings").saveSource(SOURCE_ID, self.cfg)
end

---@return boolean
function Settings:is_cookie_configured()
    return type(self.cfg.cookies) == "table" and next(self.cfg.cookies) ~= nil
end

return Settings
