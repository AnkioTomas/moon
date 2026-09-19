-- Reuse the existing official login without copying credentials into the package.
local Settings = {}
Settings.__index = Settings
function Settings:new()
    local DS = require('datastorage')
    local dir = DS:getFullDataDir() .. '/fanqie'
    local store = require('luasettings'):open(DS:getSettingsDir() .. '/fanqie.lua')
    return setmetatable({store=store, data_dir=dir,
        cache_dir=store:readSetting('download_dir', '') ~= '' and store:readSetting('download_dir') or dir .. '/cache'}, self)
end
function Settings:get(key, default) return self.store:readSetting(key, default) end
function Settings:set(key, value) self.store:saveSetting(key, value) end
function Settings:flush() self.store:flush() end
function Settings:get_download_dir() return self.cache_dir end
function Settings:is_cookie_configured() return next(self:get('cookies', {})) ~= nil end
return Settings
