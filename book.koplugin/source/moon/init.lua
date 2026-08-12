--[[--
Book (moon) 数据源适配器
  HTTP 实现见 source.moon.api

@module koplugin.book.source.moon
--]]

local Api = require("source.moon.api")
local Contract = require("source.contract")
local _ = require("gettext")

local Moon = {}

function Moon.meta()
    return {
        id = "moon",
        name = _("Book 服务"),
    }
end

local Source = {}
Source.__index = Source

function Moon.new(cfg)
    cfg = cfg or {}
    local self = setmetatable({}, Source)
    self._api = Api:new{
        base_url = cfg.base_url or "",
        token = cfg.token or "",
    }
    return self
end

function Source:id()
    return "moon"
end

function Source:name()
    return _("Book 服务")
end

function Source:capabilities()
    return {
        store = false,
        stats = true,
        progress_sync = true,
        stats_import = true,
        search = true,
        filters = true,
    }
end

function Source:configured()
    return self._api:configured()
end

function Source:ping()
    return self._api:ping()
end

function Source:listLibrary(opts)
    return Contract.normalizeList(self._api:listBooks(opts))
end

function Source:listStore(_opts)
    return nil, _("当前数据源不支持书城")
end

function Source:recentBooks(limit)
    return Contract.normalizeList(self._api:recentBooks(limit))
end

function Source:filters()
    return self._api:filters()
end

function Source:libraryStats()
    return self._api:stats()
end

function Source:stats()
    return self:libraryStats()
end

function Source:registerReadingDevice(device_id, model)
    return self._api:registerReadingDevice(device_id, model)
end

function Source:importReadingStats(payload)
    return self._api:importReadingStats(payload)
end

function Source:readingSummary()
    return self._api:readingSummary()
end

function Source:readingInsight()
    return self._api:readingInsight()
end

function Source:clearInsightCache()
    Api.clearInsightCache()
end

function Source:clearRecentCache()
    Api.clearRecentCache()
end

function Source:clearCaches()
    Api.clearRecentCache()
    Api.clearInsightCache()
end

function Source:hitokoto()
    return Api.hitokoto()
end

function Source:getProgress(filename)
    return self._api:getProgress(filename)
end

function Source:updateProgress(filename, frac, spine, page, percent_text)
    return self._api:updateProgress(filename, frac, spine, page, percent_text)
end

function Source:probeFileSize(filename)
    return self._api:probeFileSize(filename)
end

function Source:downloadBook(filename, dest_path, on_progress)
    return self._api:downloadBook(filename, dest_path, on_progress)
end

function Source:downloadCover(filename, dest_path)
    return self._api:downloadCover(filename, dest_path)
end

return Moon
