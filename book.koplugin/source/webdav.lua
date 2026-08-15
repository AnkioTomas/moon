--[[--
WebDAV 数据源门面：列目录 + 整本下载（仅异步）。

@module koplugin.book.source.webdav
--]]

local SourceBase = require("source.base")
local Client = require("source.webdav.client")
local Mapper = require("source.webdav.mapper")
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
        scrape = false,
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

--- 根据引用构造 WebDAV 书籍详情。
---@param ref BookRef
---@return BookDetail|nil, string|nil
function Source:getDetail(ref)
    return Mapper.detailFromRef(ref)
end

function Source:pingAsync(cb)
    if not self:configured() then
        cb(nil, _("未配置 WebDAV 地址或用户名"))
        return nil
    end
    return self._client:pingAsync(function(ok, err)
        if not ok then
            cb(nil, (type(err) == "table" and err.message) or err)
            return
        end
        local user = self.cfg.username or ""
        cb({ data = { display_name = user ~= "" and user or "WebDAV", username = user } })
    end)
end

function Source:listLibraryAsync(opts, cb)
    opts = opts or {}
    local path = opts.path or opts.series or ""
    return self._client:listAsync(path, function(entries, err)
        if entries then
            cb(Mapper.list(entries, path))
        else
            cb(nil, (type(err) == "table" and err.message) or err)
        end
    end)
end

function Source:materializeWholeAsync(ref, temp_path, on_progress, cb)
    return self._client:downloadAsync(ref.stable_id, temp_path, on_progress, function(ok, err)
        if ok then
            cb(true)
        else
            cb(nil, (type(err) == "table" and err.message) or err)
        end
    end)
end

--- 把书城下载文件上传到 WebDAV 根目录。
---@param local_path string
---@param filename string
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return table|nil
function Source:importBookAsync(local_path, filename, cb)
    if not self._client:configured() then
        cb(nil, _("未配置 WebDAV 地址或用户名"))
        return nil
    end
    return self._client:uploadAsync(filename, local_path, cb)
end

return WebDAV
