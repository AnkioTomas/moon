--[[--
本地数据源门面：扫描写库 + 一切查询直查数据库（仅异步）。

@module koplugin.book.source.local
--]]

local SourceBase = require("source.base")
local Client = require("source.local.client")
local Mapper = require("source.local.mapper")
local _ = require("gettext")

local Local = {}

--- 返回本地源元信息。
---@return BookSourceMeta
function Local.meta()
    return { id = "local", name = _("本地书籍"), type = "book" }
end

---@class LocalSource : SourceBase
---@field cfg table
---@field _client table
local Source = setmetatable({}, { __index = SourceBase })
Source.__index = Source

--- 构造本地源实例。
---@return LocalSource
function Local.new()
    local cfg = require("utils.settings").getSource("local")
    local meta = Local.meta()
    local self = setmetatable({
        id = meta.id,
        name = meta.name,
        type = meta.type,
        cfg = cfg,
        _client = Client.new(cfg),
    }, Source)
    return self
end

--- 返回本地源能力集。
---@return SourceCapabilities
function Source:capabilities()
    return {
        search = true,
        refresh = true,
        scrape = true,
        insight = true,
        store = false,
    }
end

--- 是否已配置本地路径。
---@return boolean
function Source:configured()
    return self._client:configured()
end

--- 本地文件直开路径（文件存在才返回；open 流程命中则不下载不复制）。
---@param ref BookRef
---@return string|nil
function Source:localPathFor(ref)
    if type(ref) ~= "table" or type(ref.stable_id) ~= "string" then
        return nil
    end
    if require("libs/libkoreader-lfs").attributes(ref.stable_id, "mode") == "file" then
        return ref.stable_id
    end
    return nil
end

--- 封面：扫描时已提取到 image 缓存目录，这里只查缓存（同步，禁止现解析）。
---@param ref BookRef
---@return BookCoverRequest|nil, string|nil
function Source:coverRequest(ref)
    local path = self._client:cachedCoverPath(ref and ref.stable_id)
    if path then
        return { url = path, headers = nil }
    end
    return nil, _("无封面")
end

function Source:listLibraryAsync(opts, cb)
    return self._client:listAsync(opts, function(rows, count, err)
        if rows then
            cb(Mapper.list(rows, count))
        else
            cb(nil, (type(err) == "table" and err.message) or err)
        end
    end)
end

function Source:filtersAsync(cb)
    return self._client:filtersAsync(cb)
end

--- 最近阅读（opens 表）。
---@param limit number|nil
---@param cb fun(data: BookListResult|nil, err: string|nil)
---@return table|nil
function Source:recentBooksAsync(limit, cb)
    return self._client:recentAsync(limit, function(rows)
        cb(Mapper.recent(rows))
    end)
end

--- 阅读统计洞察（reading_stats 表聚合）。
---@param cb fun(data: StatsInsight|nil, err: string|nil)
---@return table|nil
function Source:readingInsightAsync(cb)
    return self._client:insightAsync(function(summary, daily, daily_books)
        cb({ data = Mapper.insight(summary, daily, daily_books) })
    end)
end


--- 把书城下载文件移入本地书库根目录，并单本入库（不重扫）。
---@param temp_path string
---@param filename string
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return table|nil
function Source:importBookAsync(temp_path, filename, cb)
    return self._client:importAsync(temp_path, filename, cb)
end

--- 插件生命周期事件：桌面打开时自动扫描（节流在 client 内）。
--- 扫描会改库，扫完后若桌面正停在图书馆页则置态重建。
---@param event string
---@param payload table|nil desktop_open 时为 Desktop 实例
function Source:onEvent(event, payload)
    if event ~= "desktop_open" then
        return
    end
    local desktop = type(payload) == "table" and payload or nil
    self._scan_job = self._client:autoScanAsync(function(scanned)
        self._scan_job = nil
        if not scanned then
            return
        end
        if desktop and not desktop._closed and desktop.tab == "library" then
            desktop._library_state = nil
            desktop:rebuild()
        end
    end)
end

--- 换源关闭：取消在飞自动扫描。
function Source:close()
    local job = self._scan_job
    self._scan_job = nil
    if job and job.cancel then
        job:cancel()
    end
end

return Local
