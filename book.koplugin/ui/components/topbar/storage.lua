--[[--
顶栏剩余存储。唤醒时原地刷新。

@module koplugin.book.ui.components.topbar.storage
--]]

local DataStorage = require("datastorage")
local ffiUtil = require("ffi/util")
local util = require("util")
local Base = require("ui.components.topbar.base")

local Storage = setmetatable({}, Base)
Storage.__index = Storage
Storage.id = "storage"

function Storage:onResume()
    local text, icon = self:read()
    self:updateMetric(icon, text)
end

---@return string|nil
function Storage:read()
    if not Base.visible("storage") then
        return nil
    end
    local _, _, disk_avail = ffiUtil.df(DataStorage:getDataDir())
    if not disk_avail then
        return nil
    end
    return util.getFriendlySize(disk_avail)
end

---@return table|nil
function Storage:build()
    self.widget = nil
    self.rect = nil
    self.widget = Base.metric("hard_drive", self:read())
    return self.widget
end

return Storage
