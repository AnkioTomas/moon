--[[--
Legado（阅读 3.0）数据源（空壳）

@module koplugin.book.source.legado
--]]

local Contract = require("source.contract")
local _ = require("gettext")

local Legado = {}

function Legado.meta()
    return { id = "legado", name = _("Legado 阅读") }
end

local Source = {}
Source.__index = Source

function Legado.new(cfg)
    local self = setmetatable({}, Source)
    self.cfg = cfg or {}
    return self
end

function Source:id() return "legado" end
function Source:name() return _("Legado 阅读") end
function Source:capabilities()
    local c = Contract.defaultCapabilities()
    c.store = true
    return c
end
function Source:configured() return false end
function Source:ping() return nil, _("Legado 数据源尚未实现") end
function Source:listLibrary() return nil, _("Legado 数据源尚未实现") end
function Source:listStore() return nil, _("Legado 数据源尚未实现") end
function Source:recentBooks() return nil, _("Legado 数据源尚未实现") end
function Source:filters() return nil, _("Legado 数据源尚未实现") end
function Source:libraryStats() return nil, _("Legado 数据源尚未实现") end
function Source:stats() return self:libraryStats() end
function Source:readingInsight() return nil, _("当前数据源不支持统计") end
function Source:clearCaches() end
function Source:getProgress() return nil, _("Legado 数据源尚未实现") end
function Source:updateProgress() return nil, _("Legado 数据源尚未实现") end
function Source:downloadBook() return nil, _("Legado 数据源尚未实现") end
function Source:downloadCover() return nil, _("Legado 数据源尚未实现") end

return Legado
