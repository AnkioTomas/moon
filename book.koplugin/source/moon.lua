--[[--
Book (moon) 数据源门面
  client：HTTP wire
  mapper：wire → 领域对象

@module koplugin.book.source.moon
--]]

local Client = require("source.moon.client")
local Mapper = require("source.moon.mapper")
local SourceBase = require("source.base")
local SourceError = require("source.error")
local Contract = require("source.contract")
local _ = require("gettext")

local Moon = {}

--- 返回 Moon 源元信息。
---@return BookSourceMeta
function Moon.meta()
    return {
        id = "moon",
        name = _("Book 服务"),
    }
end

---@class MoonSource : SourceBase
---@field _client MoonClient
local Source = setmetatable({}, { __index = SourceBase })
Source.__index = Source

--- 构造 Moon 源实例。
---@return MoonSource
function Moon.new()
    local cfg = require("utils.settings").getSource("moon")
    local meta = Moon.meta()
    ---@type MoonSource
    local self = setmetatable({
        id = meta.id,
        name = meta.name,
        _client = Client:new(cfg),
    }, Source)
    return self
end

--- 返回 Moon 源能力集。
---@return SourceCapabilities
function Source:capabilities()
    return {
        library = true,
        recent = true,
        search = false,
        filters = true,
        detail = true,
        cover = true,
        whole_book = true,
        chapters = false,
        progress_pull = true,
        progress_push = true,
        insight = true,
        stats_import = true,
        store = false,
    }
end

--- 是否已配置 Moon 源。
---@return boolean
function Source:configured()
    return self._client:configured()
end

--- 返回 Moon 源配置状态。
---@return SourceConfigurationState
function Source:configurationState()
    if self:configured() then
        return "ready"
    end
    return "needs_config"
end

--- 探测 Moon 服务连通性。
---@return table|nil, SourceError|nil
function Source:ping()
    local wire, err = self._client:ping()
    if not wire then
        return nil, SourceError.wrap(err, self:configured() and "offline" or "not_configured")
    end
    return wire
end

--- 把 BookListOpts 转成 Moon list API 的 query 表。
---@param opts BookListOpts|nil
---@return table
local function listQuery(opts)
    opts = opts or {}
    return {
        page = opts.page or 1,
        pageSize = opts.page_size or 50,
        search = opts.search or "",
        series = opts.series or "",
        category = opts.category or "",
        favorite = opts.favorite or "",
        finished = opts.finished or "",
        author = opts.author or "",
    }
end

--- 列出 Moon 书库。
---@param opts BookListOpts|nil
---@return BookListResult|nil, SourceError|nil
function Source:listLibrary(opts)
    local wire, err = self._client:listBooks(listQuery(opts))
    if not wire then
        return nil, SourceError.wrap(err, "offline")
    end
    return Mapper.list(wire)
end

--- 列出 Moon 最近阅读。
---@param limit number|nil
---@return BookListResult|nil, SourceError|nil
function Source:recentBooks(limit)
    local wire, err = self._client:recentBooks(limit)
    if not wire then
        return nil, SourceError.wrap(err, "offline")
    end
    return Mapper.list(wire)
end

--- 获取 Moon 筛选条件。
---@return BookFiltersResult|nil, SourceError|nil
function Source:filters()
    local wire, err = self._client:filters()
    if not wire then
        return nil, SourceError.wrap(err, "offline")
    end
    return { data = wire.data or wire }
end

--- 清空 Moon 书库/统计相关 HTTP 缓存。
function Source:clearCaches()
    local ok, Request = pcall(require, "http.request")
    if ok and Request and Request.clearCache then
        Request.clearCache("/index/book/")
        Request.clearCache("/index/stats/")
    end
end

--- 向 Moon 注册阅读设备。
---@param device_id string
---@param model string|nil
---@return table|nil, SourceError|nil
function Source:registerReadingDevice(device_id, model)
    local wire, err = self._client:registerReadingDevice({
        device_id = device_id,
        model = model or "",
    })
    if not wire then
        return nil, SourceError.wrap(err, "protocol")
    end
    return wire
end

--- 向 Moon 导入阅读统计。
---@param payload BookStatsPayload
---@return table|nil, SourceError|nil
function Source:importReadingStats(payload)
    payload = payload or {}
    local Store = require("book.store")
    local md5_map = Store.md5FilenameMap()

    local books = {}
    local seen = {}
    for _, b in ipairs(payload.books or {}) do
        local filename = md5_map[b.md5]
        if type(filename) == "string" and filename ~= "" and not seen[filename] then
            seen[filename] = true
            books[#books + 1] = { filename = filename }
        end
    end

    local stats = {}
    for _, s in ipairs(payload.stats or {}) do
        local filename = md5_map[s.md5]
        if type(filename) == "string" and filename ~= "" then
            stats[#stats + 1] = {
                filename = filename,
                page = s.page,
                start_time = s.start_time,
                duration = s.duration,
                total_pages = s.total_pages,
                device_id = s.device_id,
            }
        end
    end

    if #books == 0 and #stats == 0 then
        return nil, SourceError.not_found(_("无已下载书籍的统计可上报（请从 Book 桌面打开过对应书籍）"))
    end

    local wire, err = self._client:importReadingStats({
        books = books,
        stats = stats,
        device_id = payload.device_id,
    })
    if not wire then
        return nil, SourceError.wrap(err, "protocol")
    end
    return wire
end

--- 获取 Moon 阅读统计洞察。
---@return BookInsightResult|nil, SourceError|nil
function Source:readingInsight()
    local wire, err = self._client:readingInsight()
    if not wire then
        return nil, SourceError.wrap(err, "offline")
    end
    return { data = Mapper.insight(wire.data or wire) }
end

--- 拉取 Moon 阅读进度。
---@param ref BookRef
---@return ProgressPosition|nil, SourceError|nil
function Source:getProgress(ref)
    local wire, err = self._client:getProgress(ref.stable_id)
    if not wire then
        return nil, SourceError.wrap(err, "offline")
    end
    local pos = Mapper.progress(wire)
    if not pos then
        return nil, SourceError.not_found(_("进度为空"))
    end
    return pos
end

--- 上报 Moon 阅读进度。
---@param ref BookRef
---@param pos ProgressPosition
---@return boolean|nil, SourceError|nil
function Source:putProgress(ref, pos)
    pos = pos or {}
    local frac = Contract.clampFraction(pos.fraction)
    local wire, err = self._client:updateProgress({
        filename = ref.stable_id,
        frac = frac,
        spine = pos.chapter_idx or 0,
        page = 0,
        percent = string.format("%.2f", frac * 100) .. "%",
    })
    if not wire then
        return nil, SourceError.wrap(err, "offline")
    end
    return true
end

--- 探测 Moon 书籍文件大小。
---@param ref BookRef
---@return number|nil
function Source:probeFileSize(ref)
    return self._client:probeFileSize(ref.stable_id)
end

--- 将整本书落盘到临时路径。
---@param ref BookRef
---@param temp_path string
---@param on_progress fun(bytes: number)|nil
---@return boolean|nil, SourceError|nil
function Source:materializeWhole(ref, temp_path, on_progress)
    local ok, err = self._client:downloadBook(ref.stable_id, temp_path, on_progress)
    if not ok then
        return nil, SourceError.wrap(err, "io")
    end
    return true
end

--- 构造 Moon 封面请求。
---@param ref BookRef
---@return BookCoverRequest|nil, SourceError|nil
function Source:coverRequest(ref)
    local req, err = self._client:coverRequest(ref.stable_id)
    if not req then
        return nil, SourceError.wrap(err, "not_found")
    end
    return req
end

--- 获取 Moon 书籍详情。
---@param ref BookRef
---@return BookDetail|nil, SourceError|nil
function Source:getDetail(ref)
    -- Moon 列表行即详情；无独立 detail API 时用 filename 构造最小详情
    return {
        ref = Contract.makeRef("moon", ref.stable_id),
        title = ref.stable_id,
        percent = 0,
    }
end

return Moon
