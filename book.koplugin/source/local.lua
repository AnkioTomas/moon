--[[--
本地数据源门面：扫描本地目录 + 整本复制（仅异步）。

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
    return { id = "local", name = _("本地书籍"), preview = false }
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
        cfg = cfg,
        _client = Client.new(cfg),
    }, Source)
    return self
end

--- 返回本地源能力集。
---@return SourceCapabilities
function Source:capabilities()
    return {
        library = true,
        recent = false,
        search = false,
        filters = true,
        refresh = true,
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

--- 是否已配置本地路径。
---@return boolean
function Source:configured()
    return self._client:configured()
end

--- 返回本地源配置状态。
---@return SourceConfigurationState
function Source:configurationState()
    if self:configured() then
        return "ready"
    end
    return "needs_config"
end

--- 根据引用构造本地书籍详情。
---@param ref BookRef
---@return BookDetail|nil, string|nil
function Source:getDetail(ref)
    return Mapper.detailFromRef(ref)
end

function Source:pingAsync(cb)
    return self._client:pingAsync(cb)
end

function Source:listLibraryAsync(opts, cb)
    return self._client:listAsync(opts, function(files, err)
        if files then
            cb(Mapper.list(files))
        else
            cb(nil, (type(err) == "table" and err.message) or err)
        end
    end)
end

function Source:filtersAsync(cb)
    return self._client:filtersAsync(cb)
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

return Local
