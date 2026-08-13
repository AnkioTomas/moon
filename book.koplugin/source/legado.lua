--[[--
Legado（阅读 3.0）数据源（空壳）

@module koplugin.book.source.legado
--]]

local Contract = require("source.contract")
local _ = require("gettext")

local Legado = {}

---@return BookSourceMeta
function Legado.meta()
    return { id = "legado", name = _("Legado 阅读") }
end

---@class LegadoSource : BookSource
---@field cfg table
local Source = {}
Source.__index = Source

---@param cfg table|nil
---@return LegadoSource
function Legado.new(cfg)
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
function Source:ping() return nil, _("Legado 数据源尚未实现") end
---@return nil, string
function Source:listLibrary() return nil, _("Legado 数据源尚未实现") end
---@return nil, string
function Source:listStore() return nil, _("Legado 数据源尚未实现") end
---@return nil, string
function Source:recentBooks() return nil, _("Legado 数据源尚未实现") end
---@return nil, string
function Source:filters() return nil, _("Legado 数据源尚未实现") end
---@return nil, string
function Source:libraryStats() return nil, _("Legado 数据源尚未实现") end
---@return nil, string
function Source:readingInsight() return nil, _("当前数据源不支持统计") end
function Source:clearCaches() end
---@return nil, string
function Source:getProgress() return nil, _("Legado 数据源尚未实现") end
---@return nil, string
function Source:updateProgress() return nil, _("Legado 数据源尚未实现") end
---@return nil, string
function Source:downloadBook() return nil, _("Legado 数据源尚未实现") end
---@return nil, string
function Source:downloadCover() return nil, _("Legado 数据源尚未实现") end

return Legado
