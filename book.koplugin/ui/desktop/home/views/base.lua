--[[--
首页视图基类：View 骨架、尺寸上下文和生命周期。
@module koplugin.book.ui.desktop.home.views.base
--]]
local View = require("ui.view")
---@class BookHomeComponent : View
---@field id string 首页组件注册标识
---@field label string 设置页显示的组件名称
---@field icon string 设置页使用的图标名称
---@field heightRange fun(self: BookHomeComponent, ctx: table|nil, opts: table|nil): table
---@field home BookHome|nil 拥有本组件的首页实例
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
---@param event string 父组件转发的事件名称或事件对象
---@return nil
function Base:onEvent(event)
    if self.widget and (event == "source_changed" or event == "home_refresh" or event == "detail_dirty") then
        self:rebuild()
    end
end

return Base
