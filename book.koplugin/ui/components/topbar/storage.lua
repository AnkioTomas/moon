--[[--
顶栏剩余存储。Resume 起每 10 分钟刷新。

@module koplugin.book.ui.components.topbar.storage
--]]

local DataStorage = require("datastorage")
local ffiUtil = require("ffi/util")
local util = require("util")
local Base = require("ui.components.topbar.base")

---@class BookTopBarStorage : BookTopBarItem
local Storage = setmetatable({}, Base)
Storage.__index = Storage
Storage.id = "storage"
Storage.interval = 600

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
