--[[--
WebDAV 数据源门面：列目录 + 整本下载。

@module koplugin.book.source.webdav
--]]

local SourceBase = require("source.base")
local SourceError = require("source.error")
local Client = require("source.webdav.client")
local Mapper = require("source.webdav.mapper")
local logger = require("logger")
local _ = require("gettext")

local WebDAV = {}

--- 返回 WebDAV 源元信息。
---@return BookSourceMeta
function WebDAV.meta()
    return { id = "webdav", name = _("WebDAV"), preview = false }
end

---@class WebdavSource : SourceBase
---@field cfg table
---@field _client table
local Source = setmetatable({}, { __index = SourceBase })
Source.__index = Source

--- 构造 WebDAV 源实例。
---@return WebdavSource
function WebDAV.new()
    local cfg = require("utils.settings").getSource("webdav")
    local meta = WebDAV.meta()
    local self = setmetatable({
        id = meta.id,
        name = meta.name,
        cfg = cfg,
        _client = Client.new(cfg),
    }, Source)
    return self
end

--- 返回 WebDAV 源能力集。
---@return SourceCapabilities
function Source:capabilities()
    return {
        library = true,
        recent = false,
        search = false,
        filters = false,
        detail = true,
        cover = false,
        whole_book = true,
        chapters = false,
        progress_pull = false,
        progress_push = false,
        insight = false,
        stats_import = false,
        store = false,
    }
end

--- 是否已配置 WebDAV。
---@return boolean
function Source:configured()
    return self._client:configured()
end

--- 返回 WebDAV 源配置状态。
---@return SourceConfigurationState
function Source:configurationState()
    if self:configured() then
        return "ready"
    end
    return "needs_config"
end

--- 探测 WebDAV 连通性。
---@return table|nil, SourceError|nil
function Source:ping()
    if not self:configured() then
        return nil, SourceError.not_configured(_("未配置 WebDAV 地址或用户名"))
    end
    local ok, err = self._client:ping()
    if not ok then
        logger.warn("book.webdav ping failed", err)
        return nil, SourceError.wrap(err, "offline")
    end
    local user = self.cfg.username or ""
    return {
        data = {
            display_name = user ~= "" and user or "WebDAV",
            username = user,
        },
    }
end

--- 列出 WebDAV 目录中的书籍。
---@param opts BookListOpts|nil
---@return BookListResult|nil, SourceError|nil
function Source:listLibrary(opts)
    opts = opts or {}
    local path = opts.path or opts.series or ""
    local entries, err = self._client:list(path)
    if not entries then
        return nil, SourceError.wrap(err, "offline")
    end
    return Mapper.list(entries, path)
end

--- 根据引用构造 WebDAV 书籍详情。
---@param ref BookRef
---@return BookDetail|nil, SourceError|nil
function Source:getDetail(ref)
    return Mapper.detailFromRef(ref)
end

--- 将 WebDAV 整本书落盘到临时路径。
---@param ref BookRef
---@param temp_path string
---@param on_progress fun(bytes: number)|nil
---@return boolean|nil, SourceError|nil
function Source:materializeWhole(ref, temp_path, on_progress)
    local ok, err = self._client:download(ref.stable_id, temp_path, on_progress)
    if not ok then
        return nil, SourceError.wrap(err, "io")
    end
    return true
end

return WebDAV
