--[[--
本地数据源门面：扫盘同步写库 + 查询走 book.catalog（本地唯一读入口）。

syncBooksAsync = 扫盘（force 强制 / 否则节流自动扫）。查询继承 SourceBase。

@module koplugin.book.source.local
--]]

local SourceBase = require("source.base")
local Client = require("source.local.client")
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
        edit = true,
        insight = true,
        store = false,
    }
end

--- 是否已配置本地路径。
---@return boolean
function Source:configured()
    return self._client:configured()
end

--- 本地文件直接登记并返回，不下载不复制。
---@param identity BookIdentity
---@param _opts table|nil
---@param cb fun(path: string|nil, err: string|nil)
---@return { cancel: fun() }
function Source:openBookAsync(identity, _opts, cb)
    local cancelled = false
    require("ui/uimanager"):nextTick(function()
        if cancelled then return end
        local path = identity.stable_id
        if type(path) ~= "string"
            or require("libs/libkoreader-lfs").attributes(path, "mode") ~= "file" then
            cb(nil, _("本地书籍文件不存在"))
            return
        end
        require("book.store").touchAsync(path, identity, nil, function(ok, err)
            if cancelled then return end
            if ok then
                cb(path)
            else
                cb(nil, err and tostring(err) or _("无法登记书籍路径"))
            end
        end)
    end)
    return { cancel = function() cancelled = true end }
end

--- 封面：扫描时已提取到 image 缓存目录，这里只查缓存（同步，禁止现解析）。
---@param identity BookIdentity
---@return BookCoverRequest|nil, string|nil
function Source:coverRequest(identity)
    local path = self._client:cachedCoverPath(identity and identity.stable_id)
    if path then
        return { url = path, headers = nil }
    end
    return nil, _("无封面")
end

--- 扫盘写 books：force 立即扫；否则走节流自动扫。
---@param opts { force?: boolean }|nil
---@param cb fun(result: SyncResult|nil, err: any)
---@return { cancel: fun() }|nil
function Source:syncBooksAsync(opts, cb)
    opts = opts or {}
    if opts.force then
        return self._client:scanAsync(function(ok, err)
            if ok == false then cb(nil, err); return end
            cb({ pulled = 1, pushed = 0, hidden = 0, conflicts = 0,
                skipped = false, scanned = true })
        end)
    end
    return self._client:autoScanAsync(function(scanned)
        cb({ pulled = scanned and 1 or 0, pushed = 0, hidden = 0, conflicts = 0,
            skipped = not scanned, reason = scanned and nil or "throttled", scanned = not not scanned })
    end)
end

--- 最近阅读：本地 books.last_open。
---@param limit number|nil
---@param cb fun(data: BookListResult|nil, err: string|nil)
---@return table|nil
function Source:recentBooksAsync(limit, cb)
    return SourceBase.recentBooksAsync(self, limit, cb)
end

--- 阅读洞察：本地 reading_stats 聚合。
---@param cb fun(data: BookInsightResult|nil, err: string|nil)
---@return table|nil

--- 把书城下载文件移入本地书库根目录，并单本入库（不重扫）。
---@param temp_path string
---@param filename string
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return table|nil
function Source:importBookAsync(temp_path, filename, cb)
    return self._client:importAsync(temp_path, filename, cb)
end

--- 手动改分类/系列 = 移动文件（分类/系列即目录层级），stable_id 跟着变。
---@param stable_id string 当前文件绝对路径
---@param category string|nil
---@param series string|nil
---@return string|nil new_stable_id, string|nil err
function Source:moveBook(stable_id, category, series)
    return self._client:moveBook(stable_id, category, series)
end

--- 用转换后的 EPUB 替换本地原书，并迁移书籍身份与附属资源。
---@param temp_path string
---@param stable_id string
---@return string|nil new_stable_id, string|nil err
function Source:replaceBook(temp_path, stable_id)
    return self._client:replaceBook(temp_path, stable_id)
end

--- 插件生命周期事件：桌面打开时自动扫描（节流在 client 内）。
--- 扫描会改库，扫完后若桌面正停在图书馆页则置态重建。
---@param event string
---@param payload table|nil desktop_open 时为 Desktop 实例
function Source:onEvent(event, payload)
    return SourceBase.onEvent(self, event, payload)
end

--- 换源关闭：取消在飞自动扫描。
function Source:close() end

return Local
