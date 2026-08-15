--[[--
Book (moon) 数据源门面
  client：HTTP wire（仅异步）
  mapper：wire → 领域对象

@module koplugin.book.source.moon
--]]

local Client = require("source.moon.client")
local Mapper = require("source.moon.mapper")
local SourceBase = require("source.base")
local ProgressPosition = require("types.book_progress")
local _ = require("gettext")

local Moon = {}

--- 返回 Moon 源元信息。
---@return BookSourceMeta
function Moon.meta()
    return {
        id = "moon",
        name = _("Book 书库"),
        type = "book",
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
        type = meta.type,
        _client = Client:new(cfg),
    }, Source)
    return self
end

--- 返回 Moon 源能力集。
---@return SourceCapabilities
function Source:capabilities()
    return {
        search = false,
        scrape = false,
        insight = true,
        store = false,
    }
end

--- 是否已配置 Moon 源。
---@return boolean
function Source:configured()
    return self._client:configured()
end

--- 生命周期事件：阅读统计上报时机由本源自决。
--- StatsSync 拖 KOReader UI 依赖链，必须函数内延迟加载（离线测试会 require 本文件）。
---@param event string
---@param _payload table|nil
function Source:onEvent(event, _payload)
    if event == "document_close" or event == "suspend" then
        require("stats.stats_sync").pushWithUi(self, false, false)
    end
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
    }
end

--- 清空 Moon 书库/统计相关 HTTP 缓存。
function Source:clearCaches()
    local ok, Request = pcall(require, "http.request")
    if ok and Request and Request.clearCache then
        Request.clearCache("/index/book/")
        Request.clearCache("/index/stats/")
    end
end

--- 构造 Moon 封面请求。
---@param ref BookRef
---@return BookCoverRequest|nil, string|nil
function Source:coverRequest(ref)
    local req, err = self._client:coverRequest(ref.stable_id)
    if not req then
        return nil, (type(err) == "table" and err.message) or err
    end
    return req
end

function Source:listLibraryAsync(opts, cb)
    return self._client:listBooksAsync(listQuery(opts), function(wire, err)
        if wire then
            cb(Mapper.list(wire))
        else
            cb(nil, (type(err) == "table" and err.message) or err)
        end
    end)
end

function Source:recentBooksAsync(limit, cb)
    return self._client:recentBooksAsync(limit, function(wire, err)
        if wire then
            cb(Mapper.list(wire))
        else
            cb(nil, (type(err) == "table" and err.message) or err)
        end
    end)
end

function Source:filtersAsync(cb)
    return self._client:filtersAsync(function(wire, err)
        if wire then
            local data = wire.data or wire
            cb({
                data = {
                    category = data.categories or data.category or {},
                    series = data.groupNames or data.series or {},
                },
            })
        else
            cb(nil, (type(err) == "table" and err.message) or err)
        end
    end)
end

function Source:importReadingStatsAsync(payload, cb)
    payload = payload or {}
    -- 本地统计身份即 stable_id（moon 源 = filename），直接透传服务器契约
    local books, stats, seen = {}, {}, {}
    for _, b in ipairs(payload.books or {}) do
        local filename = b.stable_id
        if type(filename) == "string" and filename ~= "" and not seen[filename] then
            seen[filename] = true
            books[#books + 1] = { filename = filename }
        end
    end
    for _, s in ipairs(payload.stats or {}) do
        local filename = s.stable_id
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
        cb(nil, _("无阅读统计数据"))
        return nil
    end
    return self._client:importReadingStatsAsync({
        books = books,
        stats = stats,
        device_id = payload.device_id,
    }, function(wire, err)
        if wire then
            cb(wire)
        else
            cb(nil, (type(err) == "table" and err.message) or err)
        end
    end)
end

function Source:syncAnnotationsAsync(payload, cb)
    payload = payload or {}
    local filename = payload.filename
    if type(filename) ~= "string" or filename == "" or type(payload.annotations) ~= "table" then
        cb(nil, _("无效的注解数据"))
        return nil
    end
    return self._client:syncAnnotationsAsync({
        filename = filename,
        device_id = payload.device_id,
        annotations = payload.annotations,
    }, function(wire, err)
        if wire then
            cb(wire)
        else
            cb(nil, (type(err) == "table" and err.message) or err)
        end
    end)
end

function Source:readingInsightAsync(cb)
    return self._client:readingInsightAsync(function(wire, err)
        if wire then
            cb({ data = Mapper.insight(wire.data or wire) })
        else
            cb(nil, (type(err) == "table" and err.message) or err)
        end
    end)
end

function Source:getProgressAsync(ref, cb)
    return self._client:getProgressAsync(ref.stable_id, function(wire, err)
        if not wire then
            cb(nil, (type(err) == "table" and err.message) or err)
            return
        end
        local pos = Mapper.progress(wire)
        if pos then
            cb(pos)
        else
            cb(nil, _("进度为空"))
        end
    end)
end

function Source:putProgressAsync(ref, pos, cb)
    pos = pos or {}
    local frac = ProgressPosition.clampFraction(pos.fraction)
    return self._client:updateProgressAsync({
        filename = ref.stable_id,
        frac = frac,
        spine = pos.chapter_idx or 0,
        page = 0,
        percent = string.format("%.2f", frac * 100) .. "%",
    }, function(wire, err)
        if wire then
            cb(true)
        else
            cb(nil, (type(err) == "table" and err.message) or err)
        end
    end)
end

function Source:materializeWholeAsync(ref, temp_path, on_progress, cb)
    return self._client:downloadBookAsync(ref.stable_id, temp_path, on_progress, function(ok, err)
        if ok then
            cb(true)
        else
            cb(nil, (type(err) == "table" and err.message) or err)
        end
    end)
end

return Moon
