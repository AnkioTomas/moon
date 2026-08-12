--[[--
WebDAV 数据源（空壳）

@module koplugin.book.source.webdav
--]]

local Contract = require("source.contract")
local _ = require("gettext")

local WebDAV = {}

function WebDAV.meta()
    return { id = "webdav", name = _("WebDAV") }
end

local Source = {}
Source.__index = Source

function WebDAV.new(cfg)
    local self = setmetatable({}, Source)
    self.cfg = cfg or {}
    return self
end

function Source:id() return "webdav" end
function Source:name() return _("WebDAV") end
function Source:capabilities()
    local c = Contract.defaultCapabilities()
    c.store = false
    return c
end
function Source:configured() return false end
function Source:ping() return nil, _("WebDAV 数据源尚未实现") end
function Source:listLibrary() return nil, _("WebDAV 数据源尚未实现") end
function Source:listStore() return nil, _("当前数据源不支持书城") end
function Source:recentBooks() return nil, _("WebDAV 数据源尚未实现") end
function Source:filters() return nil, _("WebDAV 数据源尚未实现") end
function Source:libraryStats() return nil, _("WebDAV 数据源尚未实现") end
function Source:stats() return self:libraryStats() end
function Source:readingInsight() return nil, _("当前数据源不支持统计") end
function Source:clearCaches() end
function Source:getProgress() return nil, _("WebDAV 数据源尚未实现") end
function Source:updateProgress() return nil, _("WebDAV 数据源尚未实现") end
function Source:downloadBook() return nil, _("WebDAV 数据源尚未实现") end
function Source:downloadCover() return nil, _("WebDAV 数据源尚未实现") end

return WebDAV
