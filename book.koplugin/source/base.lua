--[[--
数据源运行时基类。

各适配器继承本类，只覆盖自己支持的方法。
未覆盖的方法返回 SourceError(unsupported)；clearCaches / close 默认为空操作。

@module koplugin.book.source.base
@see types.book_source
--]]

local Contract = require("source.contract")
local SourceError = require("source.error")
local _ = require("gettext")

---@class SourceBase : BookSource
---@field id SourceId
---@field name string|nil
local SourceBase = {}
SourceBase.__index = SourceBase

--- 构造 SourceBase 实例。
---@param o { id: SourceId, name: string|nil }|table|nil
---@return SourceBase
function SourceBase:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

--- 返回默认全 false 能力集。
---@return SourceCapabilities
function SourceBase:capabilities()
    return Contract.defaultCapabilities()
end

--- 返回配置状态。
---@return SourceConfigurationState
function SourceBase:configurationState()
    if self:configured() then
        return "ready"
    end
    return "needs_config"
end

--- 是否已配置。
---@return boolean
function SourceBase:configured()
    return false
end

--- 探测连通（基类失败）。
---@return nil, SourceError
function SourceBase:ping()
    return nil, SourceError.not_configured(_("数据源未配置"))
end

--- 基类不支持书库，返回 SourceError。
---@param _opts BookListOpts|nil
---@return nil, SourceError
function SourceBase:listLibrary(_opts)
    return nil, SourceError.unsupported(_("当前数据源不支持书库"))
end

--- 基类不支持书城，返回 SourceError。
---@param _opts BookListOpts|nil
---@return nil, SourceError
function SourceBase:listStore(_opts)
    return nil, SourceError.unsupported(_("当前数据源不支持书城"))
end

--- 基类不支持最近阅读，返回 SourceError。
---@param _limit number|nil
---@return nil, SourceError
function SourceBase:recentBooks(_limit)
    return nil, SourceError.unsupported(_("当前数据源不支持最近阅读"))
end

--- 基类不支持筛选，返回 SourceError。
---@return nil, SourceError
function SourceBase:filters()
    return nil, SourceError.unsupported(_("当前数据源不支持筛选"))
end

--- 基类不支持统计，返回 SourceError。
---@return nil, SourceError
function SourceBase:readingInsight()
    return nil, SourceError.unsupported(_("当前数据源不支持统计"))
end

--- 清空数据源侧缓存（基类空操作）。
function SourceBase:clearCaches() end

--- 关闭数据源并释放资源（基类空操作）。
function SourceBase:close() end

--- 基类不支持进度拉取。
---@param _ref BookRef
---@return nil, SourceError
function SourceBase:getProgress(_ref)
    return nil, SourceError.unsupported(_("当前数据源不支持进度同步"))
end

--- 基类不支持进度上报。
---@param _ref BookRef
---@param _pos ProgressPosition
---@return nil, SourceError
function SourceBase:putProgress(_ref, _pos)
    return nil, SourceError.unsupported(_("当前数据源不支持进度同步"))
end

--- 探测文件大小（基类）。
---@param _ref BookRef
---@return number|nil
function SourceBase:probeFileSize(_ref)
    return nil
end

--- 基类不支持整本落盘。
---@param _ref BookRef
---@param _temp_path string
---@param _on_progress fun(bytes: number)|nil
---@return nil, SourceError
function SourceBase:materializeWhole(_ref, _temp_path, _on_progress)
    return nil, SourceError.unsupported(_("当前数据源不支持整本下载"))
end

--- 基类不支持封面请求。
---@param _ref BookRef
---@return BookCoverRequest|nil, SourceError|nil
function SourceBase:coverRequest(_ref)
    return nil, SourceError.unsupported(_("当前数据源不支持封面"))
end

--- 基类不支持详情。
---@param _ref BookRef
---@return nil, SourceError
function SourceBase:getDetail(_ref)
    return nil, SourceError.unsupported(_("当前数据源不支持详情"))
end

--- 基类不支持目录。
---@param _ref BookRef
---@return nil, SourceError
function SourceBase:getToc(_ref)
    return nil, SourceError.unsupported(_("当前数据源不支持目录"))
end

--- 基类不支持按章落盘。
---@param _ref BookRef
---@param _chapter BookChapter
---@param _temp_path string
---@return nil, SourceError
function SourceBase:materializeChapter(_ref, _chapter, _temp_path)
    return nil, SourceError.unsupported(_("当前数据源不支持按章阅读"))
end

--- 基类不支持注册阅读设备。
---@param _device_id string
---@param _model string|nil
---@return nil, SourceError
function SourceBase:registerReadingDevice(_device_id, _model)
    return nil, SourceError.unsupported(_("当前数据源不支持统计上报"))
end

--- 基类不支持导入阅读统计。
---@param _payload BookStatsPayload
---@return nil, SourceError
function SourceBase:importReadingStats(_payload)
    return nil, SourceError.unsupported(_("当前数据源不支持统计上报"))
end

return SourceBase
