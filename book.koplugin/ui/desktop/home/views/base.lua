--[[--
首页视图基类：View 骨架、尺寸上下文和生命周期。
@module koplugin.book.ui.desktop.home.views.base
--]]
local View = require("ui.view")
---@class BookHomeComponent : View
---@field id string 首页组件注册标识
---@field label string 设置页显示的组件名称
---@field icon string 设置页使用的图标名称
---@field heightRange fun(self: BookHomeComponent, ctx: table|nil, opts: table|nil): BookHomeHeightSpec
---@field showSettings fun(self: BookHomeComponent, desktop: table|nil)|nil 有组件设置时由编辑叠层调用
---@field home BookHome|nil 拥有本组件的首页实例
---@field desktop BookDesktop|nil 桌面宿主（部分组件直接挂）
---@field ctx table 当前构建上下文，提供数据源、尺寸和宿主
---@field opts table 当前布局分配的宽高和屏幕纵坐标
local Base = {}
Base.__index = Base
setmetatable(Base, View)

--- 保存构建上下文和尺寸；尺寸变化时重建内容，其余情况复用根骨架。
---@param ctx table|nil 构建上下文，提供尺寸、数据源和桌面宿主
---@param opts table|nil 布局尺寸、样式及行为选项；缺省项使用组件默认值
---@return table
function Base:build(ctx, opts)
    if ctx then self.ctx = ctx end
    if opts then
        local resized = self.opts and (self.opts.width ~= opts.width or self.opts.height ~= opts.height)
        self.opts = opts
        self.width, self.height = opts.width, opts.height
        self.host = ctx and ctx.desktop or self.host
        if resized and self.widget then return self:rebuild() end
    end
    self.ctx = self.ctx or {}
    self.opts = self.opts or { width = self.width, height = self.height, y = 0 }
    return View.build(self)
end

--- 换源、首页刷新或书籍详情变化时重建已存在的内容树。
---@param event string|table 父组件转发的事件名称或事件对象
function Base:onEvent(event)
    if self.widget and (event == "source_changed" or event == "home_refresh" or event == "detail_dirty") then
        self:rebuild()
    end
end

--- 空书架入口：整块可点，进入图书馆并清除旧的筛选和分页状态。
---@param ctx table 构建上下文；离屏视图没有桌面时点击不跳转
---@param w number 目标宽度，单位像素
---@param h number 目标高度，单位像素
---@param err string|nil 读取书架失败的原因，替代默认提示
---@return table
function Base.libraryPrompt(ctx, w, h, err)
    local Geom = require("ui/geometry")
    local UI = require("ui.components.bookui")
    local _ = require("gettext")
    local tap = require("ui.components.bookinfo").tappable(w, h, function()
        local desktop = ctx.desktop
        if not desktop or not desktop.switchTab then return end
        local library = desktop.library
        if library then
            library.filter = {}
            library.page = 1
            library.state = nil
        end
        desktop:switchTab("library")
    end)
    tap[1] = require("ui/widget/container/centercontainer"):new{
        dimen = Geom:new{ w = w, h = h },
        require("ui/widget/textwidget"):new{
            text = err or _("去图书馆挑一本 ›"),
            face = UI.face("cfont", 14),
            fgcolor = UI.muted(),
        },
    }
    return tap
end

return Base
