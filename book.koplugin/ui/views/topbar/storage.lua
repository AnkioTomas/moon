--[[--
顶栏剩余存储。Resume 起每 10 分钟刷新。

@module koplugin.book.ui.views.topbar.storage
--]]

local DataStorage = require("datastorage")
local ffiUtil = require("ffi/util")
local util = require("util")
local Base = require("ui.views.topbar.base")

---@class BookTopBarStorage : BookTopBarItem
local Storage = {}
Storage.__index = Storage
setmetatable(Storage, Base)
Storage.id = "storage"
Storage.interval = 600

--- 读取数据目录可用存储空间；设置隐藏或数据不可用时返回 nil。
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

--- 构建数据目录可用存储空间对应的指标控件；隐藏时返回零尺寸占位 Widget。
---@return table|nil
function Storage:createWidget()
    self.metric_widget = nil
    self.rect = nil
    self.metric_widget = Base.metric("hard_drive", self:read())
    return self.metric_widget or require("ui/widget/widget"):new{ dimen = require("ui/geometry"):new{ w = 0, h = 0 } }
end

return Storage
