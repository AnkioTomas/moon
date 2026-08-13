--[[--
Book (moon) 数据源适配器
  HTTP 实现见 source.moon.api

@module koplugin.book.source.moon
--]]

local Api = require("source.moon.api")
local Contract = require("source.contract")
local _ = require("gettext")

local Moon = {}

---@return BookSourceMeta
function Moon.meta()
    return {
        id = "moon",
        name = _("Book 服务"),
    }
end

---@class MoonSource : BookSource
---@field _api MoonApi
local Source = {}
Source.__index = Source

---@param cfg MoonSourceConfig|table|nil
---@return MoonSource
function Moon.new(cfg)
    cfg = cfg or {}
    local self = setmetatable({}, Source)
    self._api = Api:new{
        base_url = cfg.base_url or "",
        token = cfg.token or "",
    }
    return self
end

---@return BookCapabilities
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

---@return boolean
function Source:configured()
    return self._api:configured()
end

---@return table|nil, string|nil
function Source:ping()
    return self._api:ping()
end

---@param opts BookListOpts|nil
---@return BookListResult|nil, string|nil
function Source:listLibrary(opts)
    return Contract.normalizeList(self._api:listBooks(opts))
end

---@param _opts BookListOpts|nil
---@return nil, string
function Source:listStore(_opts)
    return nil, _("当前数据源不支持书城")
end

---@param limit number|nil
---@return BookListResult|nil, string|nil
function Source:recentBooks(limit)
    local res, err = self._api:recentBooks(limit)
    if not res then
        return nil, err
    end
    return Contract.normalizeList(res)
end

---@return BookFiltersResult|nil, string|nil
function Source:filters()
    return self._api:filters()
end

---@return BookLibraryStats|nil, string|nil
function Source:libraryStats()
    return self._api:stats()
end

---@param device_id string
---@param model string|nil
---@return table|nil, string|nil
function Source:registerReadingDevice(device_id, model)
    return self._api:registerReadingDevice(device_id, model)
end

---@param payload BookStatsPayload
---@return table|nil, string|nil
function Source:importReadingStats(payload)
    return self._api:importReadingStats(payload)
end

---@return BookInsightResult|nil, string|nil
function Source:readingInsight()
    local res, err = self._api:readingInsight()
    if not res then
        return nil, err
    end
    return res
end

function Source:clearCaches()
    Api.clearRecentCache()
    Api.clearInsightCache()
end

--- 异步拉取后回填父进程内存缓存
---@param limit number|nil
---@param res BookListResult|nil
function Source:primeRecentCache(limit, res)
    Api.primeRecentCache(limit, res)
end

---@param res BookInsightResult|nil
function Source:primeInsightCache(res)
    Api.primeInsightCache(res)
end

---@return BookHitokotoResult|nil, string|nil
function Source:hitokoto()
    return Api.hitokoto()
end

---@param filename string
---@return BookProgressResult|nil, string|nil
function Source:getProgress(filename)
    return self._api:getProgress(filename)
end

---@param filename string
---@param frac number
---@param spine number|nil
---@param page number|nil
---@param percent_text string|nil
---@return table|nil, string|nil
function Source:updateProgress(filename, frac, spine, page, percent_text)
    return self._api:updateProgress(filename, frac, spine, page, percent_text)
end

---@param filename string
---@return number|nil
function Source:probeFileSize(filename)
    return self._api:probeFileSize(filename)
end

---@param filename string
---@param dest_path string
---@param on_progress fun(bytes: number)|nil
---@return boolean|nil, string|nil
function Source:downloadBook(filename, dest_path, on_progress)
    return self._api:downloadBook(filename, dest_path, on_progress)
end

---@param filename string
---@param dest_path string
---@return boolean|nil, string|nil
function Source:downloadCover(filename, dest_path)
    return self._api:downloadCover(filename, dest_path)
end

return Moon
