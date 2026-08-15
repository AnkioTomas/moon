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
---@field type BookSourceType
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

--- 是否已配置。
---@return boolean
function SourceBase:configured()
    return false
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
---   page_changed    — 翻页（仅源身份书籍），payload = { ref, book, page, total_pages, percent, chapter_idx }
---   book_info_request — 阅读面板详情页请求书籍信息，payload = { ref, book, refresh }
---     （源可拉最新详情写 Store.putMetaAsync 后调 refresh() 重绘面板；基类空操作即可）
---@param _event string
---@param _payload table|nil
function SourceBase:onEvent(_event, _payload) end

--- 最近阅读默认从本地打开记录读取；需要远端最近列表的源可覆盖。
---@param limit number|nil
---@param cb fun(data: BookListResult|nil, err: string|nil)
---@return table
function SourceBase:recentBooksAsync(limit, cb)
    local cancelled = false
    require("ui/uimanager"):nextTick(function()
        if cancelled then
            return
        end
        local BookRef = require("types.book").BookRef
        local books = {}
        for _, row in ipairs(require("utils.db.open").recentBySource(self.id, limit)) do
            books[#books + 1] = {
                ref = BookRef.new(self.id, row.stable_id),
                title = row.title,
                authors = row.authors,
                intro = row.intro,
                category = row.category,
                percent = tonumber(row.percent) or 0,
            }
        end
        cb(require("types.book_list").new(books))
    end)
    return {
        cancel = function()
            cancelled = true
        end,
    }
end

--- 基类不支持封面请求。
---@param _ref BookRef
---@return BookCoverRequest|nil, string|nil
function SourceBase:coverRequest(_ref)
    return nil, _("当前数据源不支持封面")
end

return SourceBase
