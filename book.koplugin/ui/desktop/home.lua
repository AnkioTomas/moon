--[[--
首页拼装器：钉页组件板。长按进编辑；PageStrip 翻页。
@module koplugin.book.ui.home
--]]

local Device = require("device")
local Geom = require("ui/geometry")
local VerticalGroup = require("ui/widget/verticalgroup")
local FrameContainer = require("ui/widget/container/framecontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local GestureRange = require("ui/gesturerange")
local Blitbuffer = require("ffi/blitbuffer")
local UI = require("ui.components.bookui")
local Layout = require("ui.desktop.home.layout")
local Components = require("ui.desktop.home.registry")
local Widgets = require("ui.desktop.home.widgets")
local PageStrip = require("ui.components.pagestrip")
local Edit = require("ui.desktop.home.edit_overlay")
local View = require("ui.view")
local Screen = Device.screen
local _ = require("gettext")

---@class BookHome : View
---@field desktop BookDesktop|nil
---@field source BookSource|nil
---@field plugin BookPlugin|nil
---@field children table<string, BookHomeComponent>
---@field components table<string, BookHomeComponent>
---@field layout BookHomeLayout
---@field page number
---@field pages number
---@field visible table<string, boolean>
---@field editing boolean
---@field widget table|nil
local Home = {}
Home.__index = Home
setmetatable(Home, View)

--- 初始化首页持有的组件映射、布局和分页状态，保留已有状态。
---@param self BookHome 当前视图或布局实例
---@return nil
local function ensure(self)
    if not self.components then self.components = self.children end
    if not self.layout then self.layout = Layout.new() end
    if not self.page then self.page = 1 end
    if not self.pages then self.pages = 1 end
    if self.editing == nil then self.editing = false end
end

--- 按组件注册顺序把同一事件和参数分发给子视图。
---@param self BookHome 当前视图或布局实例
---@param method string 子组件上的方法名
---@param ... any 原样传给目标方法的参数
---@return nil
local function broadcast(self, method, ...)
    for _i, id in ipairs(Components.enabledLayout()) do
        local child = self.components[id]
        if child and child[method] then child[method](child, ...) end
    end
end

--- 暂停离开当前页的组件，仅恢复当前首页中可见的组件。
---@param self BookHome 当前视图或布局实例
---@return nil
local function applyVisible(self)
    local visible = self.visible or {}
    local active = self.lifecycle.state == "Resume" and self.desktop and self.desktop.tab == "home"
    local layout = Components.enabledLayout()
    for _i, id in ipairs(layout) do
        local child = self.components[id]
        if child and child.lifecycle.state == "Resume" and not (active and visible[id]) then
            child:onPause()
        end
    end
    if not active then return end
    for _i, id in ipairs(layout) do
        local child = self.components[id]
        if child and visible[id]
            and child.lifecycle.state ~= "Resume"
            and child.lifecycle.state ~= "Destroy" then
            child:onResume()
        end
    end
end

--- 按启用配置创建缺失组件，按生命周期退役不再需要的实例。
---@return nil
function Home:sync()
    if self.lifecycle.state == "Destroy" then return end
    ensure(self)
    local wanted = {}
    for _i, id in ipairs(Components.enabledLayout()) do
        wanted[id] = true
        if not self.components[id] then
            local class = Components.find(id)
            if class then
                local child = class:new()
                child.home = self
                child.name = "home." .. id
                self.components[id] = child
            end
        end
    end
    for id, child in pairs(self.components) do
        if not wanted[id] then
            child:onDestroy()
            self.components[id] = nil
        end
    end
end

--- 首次显示时按真实屏幕高度生成默认分页并落盘。
---@param self BookHome 当前视图或布局实例
---@param ctx table 构建上下文，提供尺寸、数据源和桌面宿主
---@param body_h number 扣除固定控件后的正文高度，单位像素
---@return nil
local function ensureLayout(self, ctx, body_h)
    if not Components.needsLayout() then return end
    local placements = Components.widgets()
    local gap = UI.sz(8)
    local inset = UI.pagePad()
    local inner_w = math.max(1, ctx.width - inset * 2)
    local inner_h = math.max(1, body_h - inset * 2)
    local ranges = {}
    for _i, place in ipairs(placements) do
        local comp = self.components[place.id]
        if comp then
            local range = comp:heightRange(ctx, { width = inner_w, height = inner_h })
            range.id = place.id
            ranges[#ranges + 1] = range
        end
    end
    local packs = self.layout:paginate(ranges, inner_h, gap)
    local next_list = Widgets.applyPacks(placements, packs)
    Components.saveWidgets(next_list)
end

--- 移除指定组件的摆放记录并刷新首页布局。
---@param self BookHome 当前视图或布局实例
---@param id string 组件、分页或数据源的标识
---@return nil
local function deleteWidget(self, id)
    local list = Components.widgets()
    if #list <= 1 then return end
    local out = {}
    for _i, item in ipairs(list) do
        if item.id ~= id then out[#out + 1] = item end
    end
    Components.saveWidgets(out)
    self:updateView()
end

--- 在当前页内移动指定组件，保存顺序并重新排版。
---@param self BookHome 当前视图或布局实例
---@param id string 组件、分页或数据源的标识
---@param delta number 相对于当前位置的偏移量
---@return nil
local function moveInPage(self, id, delta)
    local list = Components.widgets()
    local item = Widgets.find(list, id)
    if not item then return end
    local page_items = Widgets.onPage(list, item.page)
    local pos
    for i, row in ipairs(page_items) do
        if row.id == id then pos = i break end
    end
    if not pos then return end
    local next_pos = pos + delta
    if next_pos < 1 or next_pos > #page_items then return end
    local a, b = page_items[pos], page_items[next_pos]
    a.order, b.order = b.order, a.order
    Components.saveWidgets(list)
    self:updateView()
end

--- 把指定组件移到相邻页，保存分页位置并重新排版。
---@param self BookHome 当前视图或布局实例
---@param id string 组件、分页或数据源的标识
---@param delta_page number 目标页相对于当前页的偏移量
---@return nil
local function movePage(self, id, delta_page)
    local list = Components.widgets()
    local item = Widgets.find(list, id)
    if not item then return end
    local target = item.page + delta_page
    if target < 1 then return end
    local pages = Widgets.pageCount(list)
    if target > pages + 1 then target = pages + 1 end
    item.page = target
    item.order = #Widgets.onPage(list, target) + 1
    Components.saveWidgets(Widgets.reindex(list))
    self.page = target
    self:updateView()
end

--- 根据当前组件位置生成可用的页内移动和跨页移动操作。
---@param self BookHome 当前视图或布局实例
---@param id string 组件、分页或数据源的标识
---@return nil
local function showMove(self, id)
    local list = Components.widgets()
    local item = Widgets.find(list, id)
    if not item then return end
    local page_items = Widgets.onPage(list, item.page)
    local pos
    for i, row in ipairs(page_items) do
        if row.id == id then pos = i break end
    end
    Edit.showMoveDialog({
        can_up = pos and pos > 1,
        can_down = pos and pos < #page_items,
        can_prev_page = item.page > 1,
        can_next_page = true,
        on_up = function() moveInPage(self, id, -1) end,
        on_down = function() moveInPage(self, id, 1) end,
        on_prev_page = function() movePage(self, id, -1) end,
        on_next_page = function() movePage(self, id, 1) end,
    })
end

--- 打开组件高度设置，应用默认高度、填满或指定高度后重排。
---@param self BookHome 当前视图或布局实例
---@param id string 组件、分页或数据源的标识
---@param range BookHomeHeightSpec 组件内容高度
---@param placement table 当前组件保存的页码、顺序和高度记录
---@return nil
local function showHeight(self, id, range, placement)
    local comp = Components.find(id)
    Edit.showHeightDialog({
        label = comp and comp.label or id,
        range = range,
        current = placement.height,
        on_apply = function(height)
            local list = Components.widgets()
            local item = Widgets.find(list, id)
            if not item then return end
            item.height = height
            Components.saveWidgets(list)
            self:updateView()
        end,
    })
end

--- 未上屏的组件均可添加；当前页放不下则落到新页。
---@param self BookHome 当前视图或布局实例
---@param body_h number 扣除固定控件后的正文高度，单位像素
---@param width number 目标宽度，单位像素
---@return nil
local function showAdd(self, body_h, width)
    local list = Components.widgets()
    local placed = {}
    for _i, item in ipairs(list) do placed[item.id] = true end
    local candidates = {}
    for _i, comp in ipairs(Components.components) do
        if not placed[comp.id] then
            candidates[#candidates + 1] = { id = comp.id, label = comp.label }
        end
    end
    if #candidates == 0 then return end
    Edit.showAddDialog(candidates, function(id)
        local next_list = Components.widgets()
        local ctx = self.desktop and self.desktop:ctx() or { width = self.width, height = self.height, source = self.source, plugin = self.plugin }
        local inset = UI.pagePad()
        local inner_w = math.max(1, width - inset * 2)
        local inner_h = math.max(1, body_h - inset * 2)
        local gap = UI.sz(8)
        local page_items = Widgets.onPage(next_list, self.page)
        local mins = {}
        for _i, place in ipairs(page_items) do
            local spec = self.components[place.id] or Components.find(place.id)
            if spec then
                mins[#mins + 1] = spec:heightRange(ctx, { width = inner_w, height = inner_h }).height
            end
        end
        local spec = Components.find(id)
        local need = spec and spec:heightRange(ctx, { width = inner_w, height = inner_h }).height or 1
        local fits = #page_items == 0 or Widgets.canFit(mins, need, inner_h, gap)
        local page, order = Widgets.appendSlot(next_list, self.page, fits)
        self.page = page
        next_list[#next_list + 1] = {
            id = id,
            page = page,
            order = order,
            height = "default",
        }
        Components.saveWidgets(next_list)
        self:updateView()
    end)
end

--- 按当前尺寸和配置拼装组件布局，返回供根骨架安装的内容树。
---@param self BookHome 当前视图或布局实例
---@return table
local function assemble(self)
    ensure(self)
    local ctx = self.desktop and self.desktop:ctx() or { width = self.width, height = self.height, source = self.source, plugin = self.plugin }
    ctx.width = self.width or ctx.width
    ctx.height = self.height or ctx.height
    local w = ctx.width
    local h = ctx.height
    local strip_h = PageStrip.bandH()
    local body_h = math.max(1, h - strip_h)

    if self.desktop and not self.offscreen then ensureLayout(self, ctx, body_h) end

    local can_add = false
    if self.editing then
        local list = Components.widgets()
        local placed = {}
        for _i, item in ipairs(list) do placed[item.id] = true end
        for _i, comp in ipairs(Components.components) do
            if not placed[comp.id] then
                can_add = true
                break
            end
        end
    end

    local widget_h = body_h

    local wrap
    if self.editing then
        wrap = function(widget, meta)
            local child = self.components[meta.id]
            return Edit.wrap(widget, meta, {
                on_delete = function(id) deleteWidget(self, id) end,
                on_move = function(id) showMove(self, id) end,
                on_height = function(id, range, placement)
                    showHeight(self, id, range, placement)
                end,
                on_settings = child and child.showSettings and function(id)
                    local inst = self.components[id]
                    if inst then inst:showSettings(self.desktop) end
                end or nil,
            })
        end
    end

    local body, page, pages, visible = self.layout:build(ctx, self.components, self.page, {
        body_height = widget_h,
        wrap = wrap,
    })
    self.page = page or 1
    self.pages = pages or 1
    self.visible = visible or {}

    local actions
    if self.editing then
        actions = {}
        if can_add then
            actions[#actions + 1] = {
                icon = "add",
                on_tap = function() showAdd(self, widget_h, w) end,
            }
        end
        actions[#actions + 1] = {
            icon = "check",
            on_tap = function() self:exitEdit() end,
        }
    end
    local column = { align = "left", body }
    column[#column + 1] = PageStrip.widget({
        width = w,
        page = self.page,
        pages = self.pages,
        center = self.editing and "title" or "dots",
        title = _("完成"),
        actions = actions,
        on_prev = function() self:turn(-1) end,
        on_next = function() self:turn(1) end,
        on_center = self.editing and function() self:exitEdit() end or nil,
    })

    local root = VerticalGroup:new(column)
    local holder = InputContainer:new{
        dimen = Geom:new{ w = w, h = h },
    }
    holder[1] = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        width = w,
        height = h,
        dimen = Geom:new{ w = w, h = h },
        root,
    }
    if not self.editing then
        holder.ges_events = {
            HoldHomeEdit = {
                GestureRange:new{ ges = "hold", range = function() return holder.dimen end },
            },
        }
        holder.onHoldHomeEdit = function()
            self:enterEdit()
            return true
        end
    end
    return holder
end

--- 将首页根节点安装到桌面内容槽；非首页 Tab 或已销毁实例不安装。
---@param self BookHome 当前视图或布局实例
---@return nil
local function install(self)
    local desktop = self.desktop
    if self.lifecycle.state == "Destroy" or not desktop or not desktop.lifecycle
        or desktop.lifecycle.state == "Destroy" then
        return
    end
    if desktop.tab ~= "home" then return end
    local root = desktop[1] and desktop[1][1]
    local page = self.widget
    if not root or not page then return end
    local h = desktop:contentHeight()
    local w = Screen:getWidth()
    if page.dimen then
        page.dimen.w = w
        page.dimen.h = h
    else
        page.dimen = Geom:new{ w = w, h = h }
    end
    page.overlap_offset = { 0, UI.topBarH() }
    desktop.view:replaceRegion("content", page)
end

--- 同步组件实例并补发创建阶段，然后拼装当前首页内容树。
---@return table widget 当前首页内容树
function Home:createWidget()
    self:sync()
    for _, child in pairs(self.components) do
        if child.lifecycle.state == "new" then child:onCreate() end
    end
    return assemble(self)
end

--- 把首页页码限制在有效范围内，页码变化时刷新布局。
---@param delta number 相对于当前位置的偏移量
---@return nil
function Home:turn(delta)
    local next_page = math.max(1, math.min(self.pages or 1, (self.page or 1) + delta))
    if next_page == self.page then return end
    self.page = next_page
    self:updateView()
end

--- 进入首页组件编辑模式，重复进入时不重建。
---@return nil
function Home:enterEdit()
    if self.editing then return end
    self.editing = true
    self:updateView()
end

--- 退出编辑模式并保存组件布局，然后恢复普通首页内容。
---@return nil
function Home:exitEdit()
    if not self.editing then return end
    self.editing = false
    Components.saveWidgets(Components.widgets())
    self:updateView()
end

--- 重建首页内容、同步可见组件生命周期并安装到桌面内容槽。
---@return table
function Home:updateView()
    if self.lifecycle.state == "Destroy" then return self.widget end
    self:rebuild()
    applyVisible(self)
    install(self)
    return self.widget
end

--- 为普通首页绑定桌面刷新宿主并构建根骨架；离屏首页不绑定宿主。
---@return nil
function Home:onCreate()
    self.host = not self.offscreen and self.desktop or nil
    self:build()
end

--- 离屏：等可见组件 load 完。
---@param done fun(data:any, err:any)
---@return table|nil
function Home:loadData(done)
    if not self.offscreen then
        done(self.data)
        return
    end
    local children = {}
    for id in pairs(self.visible or {}) do
        if self.components[id] then children[#children + 1] = self.components[id] end
    end
    local left = #children
    if left == 0 then done(self.data) return end
    local failure
    for _, child in ipairs(children) do
        child:load(function(ok, err)
            if self.lifecycle.state == "Destroy" then return end
            if not ok then failure = failure or err end
            if ok and child.widget then child:rebuild() end
            left = left - 1
            if left == 0 then
                if failure then done(nil, failure) else done(self.data) end
            end
        end)
    end
end

--- 首页 Tab 活跃时恢复可见组件。
---@return nil
function Home:onResume()
    applyVisible(self)
end

--- 保存并退出编辑态，然后暂停当前仍在运行的组件。
---@return nil
function Home:onPause()
    if self.editing then
        self.editing = false
        Components.saveWidgets(Components.widgets())
    end
    for _i, id in ipairs(Components.enabledLayout()) do
        local child = self.components[id]
        if child and child.lifecycle.state == "Resume" then
            child:onPause()
        end
    end
end

--- 销毁首页组件并清除桌面、内容树和编辑状态引用。
---@return nil
function Home:onDestroy()
    broadcast(self, "onDestroy")
    self.widget = nil
    self.desktop = nil
    self.components = {}
    self.editing = false
end

--- 处理布局设置、编辑、换源和滑动事件，其余事件继续分发给子组件。
---@param event string|table 父组件转发的事件名称或事件对象
---@param payload any 与事件一起传入的数据
---@return nil
function Home:onEvent(event, payload)
    if self.lifecycle.state == "Destroy" then return end
    if event == "home_changed" then
        self:updateView()
        return
    end
    if event == "source_changed" or event == "home_refresh" or event == "detail_dirty" then
        if event == "source_changed" then
            self.source = payload
            for _, child in pairs(self.components or {}) do
                if child.ctx then child.ctx.source = payload end
            end
        end
        broadcast(self, "onEvent", event, payload)
        self:updateView()
        return
    end
    if event == "swipe" then
        if self.editing or not payload then return end
        if payload.direction == "west" then
            self:turn(1)
        elseif payload.direction == "east" then
            self:turn(-1)
        end
        return
    end
    broadcast(self, "onEvent", event, payload)
end

return Home
