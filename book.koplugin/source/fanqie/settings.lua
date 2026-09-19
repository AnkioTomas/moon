--[[--
番茄源配置：落在 utils.settings.getSource("fanqie")。

旧 fanqie.koplugin 的 Cookie 在 KOReader `settings/fanqie.lua`；
本源配置里还没有 cookies 时迁入一次，之后只读写 `.moon/settings/fanqie.lua`。

@module koplugin.book.source.fanqie.settings
--]]

local SOURCE_ID = "fanqie"

local Settings = {}
Settings.__index = Settings

local migrated = false

---@param cfg table
local function migrateLegacyCookies(cfg)
    if migrated then return end
    migrated = true
    if type(cfg.cookies) == "table" and next(cfg.cookies) then return end
    local ok_ds, DS = pcall(require, "datastorage")
    if not ok_ds then return end
    local path = DS:getSettingsDir() .. "/fanqie.lua"
    local ok, store = pcall(function()
        return require("luasettings"):open(path)
    end)
    if not ok or not store then return end
    local cookies = store:readSetting("cookies")
    if type(cookies) ~= "table" or not next(cookies) then return end
    cfg.cookies = cookies
    require("utils.settings").saveSource(SOURCE_ID, cfg)
end

---@return FanqieSettings
function Settings:new()
    local cfg = require("utils.settings").getSource(SOURCE_ID)
    migrateLegacyCookies(cfg)
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
