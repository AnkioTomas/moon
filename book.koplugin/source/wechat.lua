--[[--
微信读书数据源（空壳）

@module koplugin.book.source.wechat
--]]

local Contract = require("source.contract")
local _ = require("gettext")

local WeChat = {}

---@return BookSourceMeta
function WeChat.meta()
    return { id = "wechat", name = _("微信读书") }
end

---@class WechatSource : BookSource
---@field cfg table
local Source = {}
Source.__index = Source

---@param cfg table|nil
---@return WechatSource
function WeChat.new(cfg)
    local self = setmetatable({}, Source)
    self.cfg = cfg or {}
    return self
end

---@return BookCapabilities
function Source:capabilities()
    local c = Contract.defaultCapabilities()
    c.store = true
    return c
end
---@return boolean
function Source:configured() return false end
---@return nil, string
function Source:ping() return nil, _("微信读书数据源尚未实现") end
---@return nil, string
function Source:listLibrary() return nil, _("微信读书数据源尚未实现") end
---@return nil, string
function Source:listStore() return nil, _("微信读书数据源尚未实现") end
---@return nil, string
function Source:recentBooks() return nil, _("微信读书数据源尚未实现") end
---@return nil, string
function Source:filters() return nil, _("微信读书数据源尚未实现") end
---@return nil, string
function Source:libraryStats() return nil, _("微信读书数据源尚未实现") end
---@return nil, string
function Source:readingInsight() return nil, _("当前数据源不支持统计") end
function Source:clearCaches() end
---@return nil, string
function Source:getProgress() return nil, _("微信读书数据源尚未实现") end
---@return nil, string
function Source:updateProgress() return nil, _("微信读书数据源尚未实现") end
---@return nil, string
function Source:downloadBook() return nil, _("微信读书数据源尚未实现") end
---@return nil, string
function Source:downloadCover() return nil, _("微信读书数据源尚未实现") end

return WeChat
