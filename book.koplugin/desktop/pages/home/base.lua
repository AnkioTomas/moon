--[[--
首页组件基类：一个绘制槽 + 活跃标志 + 一个在飞请求。

  Home ──build(ctx, opts)──▶ slot [ createWidget() ]     每次首页重排都新建
  组件自己 ──refresh()──▶ slot[1] 换成新 createWidget()，只刷新 slot 绘制过的矩形
  Home ──activate()/deactivate()/destroy()──▶ active 翻转 + onActivate/onDeactivate/onDestroy

active 为假时 refresh 只换内容不刷屏、request 不发请求；deactivate 取消在飞请求，
被取消 / 被顶掉的请求回调不落地。

@module koplugin.book.desktop.pages.home.base
--]]

local Event = require("ui/event")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

---@class BookHomeComponent
---@field showSettings fun(self: BookHomeComponent, desktop: BookDesktop)|nil
---@field id string 首页组件注册标识
---@field label string 设置页显示的组件名称
---@field icon string 设置页使用的图标名称
---@field heightRange fun(self: BookHomeComponent, ctx: table|nil, opts: table|nil): BookHomeHeightSpec
---@field createWidget fun(self: BookHomeComponent): table 按 self.ctx / self.opts 构建内容
---@field home BookHome|nil 拥有本组件的首页实例
---@field desktop BookDesktop|nil 桌面宿主，build 时取自 ctx
---@field ctx table 当前构建上下文，提供数据源、尺寸和宿主
---@field opts table 当前布局分配的宽高
---@field slot table|nil 当前绘制槽；destroy 后为 nil
---@field active boolean 首页可见且处于前台
---@field data any 请求得到的显示数据
---@field shelf_key string|nil 读最近书架的组件在构建时登记的显示快照签名
local Base = {}
Base.__index = Base

--- 绘制槽：尺寸固定为布局分配的宽高，绘制时记下屏幕坐标供局部刷新。
local Slot = WidgetContainer:extend{}

function Slot:getSize()
    return self.dimen
end

function Slot:paintTo(bb, x, y)
    self.painted = Geom:new{ x = x, y = y, w = self.dimen.w, h = self.dimen.h }
    self[1]:paintTo(bb, x, y)
end

---@generic T : BookHomeComponent
---@param self T 组件类表
---@param opts table|nil
---@return T
function Base:new(opts)
    opts = opts or {}
    opts.active = false
    return setmetatable(opts, self)
end

--- 按布局分配的尺寸新建绘制槽。
---@param ctx table 构建上下文，提供尺寸、数据源和桌面宿主
---@param opts table 布局分配的 width / height
---@return table
function Base:build(ctx, opts)
    self.ctx, self.opts, self.desktop = ctx, opts, ctx.desktop
    self.slot = Slot:new{ dimen = Geom:new{ w = opts.width, h = opts.height }, self:createWidget() }
    return self.slot
end

--- 只刷新本组件绘制过的矩形；未绘制或不活跃时跳过（整页重绘会带上它）。
function Base:dirty()
    local slot = self.slot
    if not (self.active and slot and slot.painted and self.desktop) then return end
    UIManager:setDirty(self.desktop, "ui", slot.painted:copy())
end

--- 原地换掉槽内内容并局部刷新。
function Base:refresh()
    local slot = self.slot
    if not slot then return end
    local old = slot[1]
    slot[1] = self:createWidget()
    old:free()
    self:dirty()
end

function Base:activate()
    if self.active then return end
    self.active = true
    self:onActivate()
end

function Base:deactivate()
    if not self.active then return end
    self.active = false
    -- 封面等图片控件收到后取消在飞下载。
    if self.slot then self.slot:handleEvent(Event:new("HomePause")) end
    self:onDeactivate()
end

function Base:destroy()
    self:deactivate()
    self:onDestroy()
    self.slot = nil
end

function Base:onActivate() end
function Base:onDeactivate() end
function Base:onDestroy() end

--- 递归按键序拼接，同内容的两张表得到同一串。
---@param value any
---@param out string[]
local function encode(value, out)
    if type(value) ~= "table" then
        out[#out + 1] = type(value) .. ":" .. tostring(value)
        return
    end
    local keys = {}
    for k in pairs(value) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    out[#out + 1] = "{"
    for _idx, k in ipairs(keys) do
        out[#out + 1] = tostring(k)
        encode(value[k], out)
    end
    out[#out + 1] = "}"
end

--- 最近书架显示快照签名；参数即 Catalog.recentShelf 的三个返回值。
---@return string
function Base.shelfKey(recent, reading, err)
    local out = {}
    encode({ recent, reading, err }, out)
    return table.concat(out, "\31")
end

--- 读当前源的最近书架；返回 Catalog.recentShelf 的三个值。
---@param ctx table 构建上下文
---@return table|nil recent, table[] reading, string|nil err
function Base.readShelf(ctx)
    local source = ctx.source or (ctx.desktop and ctx.desktop.source)
    return require("book.catalog").recentShelf(source and source.id, 24)
end

--- 读最近书架并登记签名（shelf_changed 据此判断要不要重建）；返回 Catalog.recentShelf 的三个值。
---@return table|nil recent, table[] reading, string|nil err
function Base:shelf()
    local recent, reading, err = Base.readShelf(self.ctx)
    self.shelf_key = Base.shelfKey(recent, reading, err)
    return recent, reading, err
end

--- 有插件实例时打开书籍，否则（离屏预览）经桌面打开详情。
---@param ctx table 构建上下文
---@param book table
function Base.openBook(ctx, book)
    local plugin = ctx.plugin or (ctx.desktop and ctx.desktop.plugin)
    if plugin then
        require("desktop.open").book(plugin, book)
    elseif ctx.desktop then
        require("desktop.detail").open(ctx.desktop, "library", book)
    end
end

--- 换源 / 首页刷新 / 详情变化由首页整页重建；这里只处理书架同步。
--- shelf_changed 只重建读最近书架（登记了 shelf_key）且显示数据确有变化的组件：
--- 远端对账每次都整表 upsert，计数不能说明变化，重建会让封面重新走一遍占位→出图。
---@param event string|table 父组件转发的事件名称或事件对象
function Base:onEvent(event)
    if event ~= "shelf_changed" or not (self.shelf_key and self.active) then return end
    local key = Base.shelfKey(Base.readShelf(self.ctx))
    if key ~= self.shelf_key then self:refresh() end
end

--- 空书架入口：整块可点，进入图书馆并清除旧的筛选和分页状态。
---@param ctx table 构建上下文；离屏视图没有桌面时点击不跳转
---@param w number 目标宽度，单位像素
---@param h number 目标高度，单位像素
---@param err string|nil 读取书架失败的原因，替代默认提示
---@return table
function Base.libraryPrompt(ctx, w, h, err)
    local CenterContainer = require("ui/widget/container/centercontainer")
    local Theme = require("ui.themes")
    local Tap = require("ui.themes.widgets.tap")
    local Text = require("ui.themes.widgets.text")
    local _ = require("gettext")
    local label = Text.line("body", err or _("去图书馆挑一本 ›"), { width = w, color = Theme.current().color.muted })
    return Tap.wrap(CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, label }, function()
        local desktop = ctx.desktop
        if not desktop then return end
        desktop.library:reset()
        desktop:switchTab("library")
    end)
end

return Base
