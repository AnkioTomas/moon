--[[--
WebDAV 数据源（空壳）

@module koplugin.book.source.webdav
--]]

local Contract = require("source.contract")
local _ = require("gettext")

local WebDAV = {}

---@return BookSourceMeta
function WebDAV.meta()
    return { id = "webdav", name = _("WebDAV") }
end

---@class WebdavSource : BookSource
---@field cfg table
local Source = {}
Source.__index = Source

---@param cfg table|nil
---@return WebdavSource
function WebDAV.new(cfg)
    local self = setmetatable({}, Source)
    self.cfg = cfg or {}
    return self
end

---@return BookCapabilities
function Source:capabilities()
    local c = Contract.defaultCapabilities()
    c.store = false
    return c
end
---@return boolean
function Source:configured() return false end
---@return nil, string
function Source:ping() return nil, _("WebDAV 数据源尚未实现") end
---@return nil, string
function Source:listLibrary() return nil, _("WebDAV 数据源尚未实现") end
---@return nil, string
function Source:listStore() return nil, _("当前数据源不支持书城") end
---@return nil, string
function Source:recentBooks() return nil, _("WebDAV 数据源尚未实现") end
---@return nil, string
function Source:filters() return nil, _("WebDAV 数据源尚未实现") end
---@return nil, string
function Source:libraryStats() return nil, _("WebDAV 数据源尚未实现") end
---@return nil, string
function Source:readingInsight() return nil, _("当前数据源不支持统计") end
function Source:clearCaches() end
---@return nil, string
function Source:getProgress() return nil, _("WebDAV 数据源尚未实现") end
---@return nil, string
function Source:updateProgress() return nil, _("WebDAV 数据源尚未实现") end
---@return nil, string
function Source:downloadBook() return nil, _("WebDAV 数据源尚未实现") end
---@return nil, string
function Source:downloadCover() return nil, _("WebDAV 数据源尚未实现") end

return WebDAV
