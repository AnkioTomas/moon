--[[--
数据源运行时基类。

各适配器继承本类，只覆盖自己支持的方法。
未覆盖的方法返回字符串错误；clearCaches / close 默认为空操作。

@module koplugin.book.source.base
@see types.book_source
--]]

local SourceCapabilities = require("types.book_source").SourceCapabilities
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
    return SourceCapabilities.defaults()
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
---@return nil, string
function SourceBase:ping()
    return nil, _("数据源未配置")
end

--- 清空数据源侧缓存（基类空操作）。
function SourceBase:clearCaches() end

--- 关闭数据源并释放资源（基类空操作）。
function SourceBase:close() end

--- 插件生命周期事件通知（基类空操作，各源按需覆写）。
--- 事件清单：
---   reader_open     — Reader 实例创建（Reader 侧插件 init）
---   reader_ready    — 文档加载渲染完毕（= 文档打开 / 阅读就绪；切章会再次触发）
---   document_close  — 关闭文档
---   chapter_changed — 按章会话切换章节，payload = { ref, chapter_idx, book }
---   （切章会关旧文档再开新文档：CloseDocument 不清会话，reader_ready 会再触发）
---   fm_open         — FileManager 主界面显示
---   desktop_open    — Book 桌面打开并可见，payload = Desktop 实例
---   suspend         — 设备休眠前（有打开文档时）
---@param _event string
---@param _payload table|nil
function SourceBase:onEvent(_event, _payload) end

--- 探测文件大小（基类）。
---@param _ref BookRef
---@return number|nil
function SourceBase:probeFileSize(_ref)
    return nil
end

--- 基类不支持封面请求。
---@param _ref BookRef
---@return BookCoverRequest|nil, string|nil
function SourceBase:coverRequest(_ref)
    return nil, _("当前数据源不支持封面")
end

return SourceBase
