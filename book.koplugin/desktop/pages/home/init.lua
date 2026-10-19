--[[--
首页拼装器：钉页组件板。长按进编辑；底部主题翻页条（编辑态中间是「添加 / 完成」）。

  +-----------------------------+
  | [组件]                      |   Layout:build 按钉页记录排当前页
  | [组件]                      |
  | [<]       ·  ●  ·       [>] |
  +-----------------------------+

每次 updateView 都新建整页（组件 build 新建各自的槽）；页内变化走 desktop:updateView。
组件的 activate / deactivate 只由 applyVisible 按「首页前台 + 本页可见」驱动。

@module koplugin.book.ui.home
--]]

local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Layout = require("desktop.pages.home.layout")
local Components = require("desktop.pages.home.registry")
local Widgets = require("desktop.pages.home.placements")
local Edit = require("desktop.pages.home.edit")
local Theme = require("ui.themes")
local Box = require("ui.themes.widgets.box")
local Button = require("ui.themes.widgets.button")
local Pager = require("ui.themes.widgets.pager")
local _ = require("gettext")

---@class BookHome
---@field desktop BookDesktop
---@field components table<string, BookHomeComponent>
---@field page number
---@field pages number
---@field visible table<string, boolean>
---@field editing boolean
---@field active boolean 首页 Tab 处于前台
local Home = {}
Home.__index = Home

---@param opts table { desktop }
---@return BookHome
function Home:new(opts)
    opts.components = {}
    opts.page, opts.pages = 1, 1
    opts.visible = {}
    opts.editing = false
    opts.active = false
    return setmetatable(opts, self)
end

--- 首页在前台时整页重建；否则等下次切回首页（switchTab 必然重建）。
---@param self BookHome
local function redraw(self)
    local desktop = self.desktop
    if desktop.closed or desktop.tab ~= "home" then return end
    desktop:updateView()
end

--- 按组件注册顺序把同一事件和参数分发给子视图。
---@param self BookHome 当前视图或布局实例
---@param method string 子组件上的方法名
---@param ... any 原样传给目标方法的参数
local function broadcast(self, method, ...)
    for _i, id in ipairs(Components.enabledLayout()) do
        local child = self.components[id]
        if child and child[method] then child[method](child, ...) end
    end
end

--- 暂停离开当前页的组件，仅恢复当前首页中可见的组件。
---@param self BookHome 当前视图或布局实例
local function applyVisible(self)
    local front = self.active and self.desktop.tab == "home"
    for _i, id in ipairs(Components.enabledLayout()) do
        local child = self.components[id]
        if child and not (front and self.visible[id]) then child:deactivate() end
    end
    if not front then return end
    for id in pairs(self.visible) do
        local child = self.components[id]
        if child then child:activate() end
    end
end

--- 按启用配置创建缺失组件，按生命周期退役不再需要的实例。
function Home:sync()
    local wanted = {}
    for _i, id in ipairs(Components.enabledLayout()) do
        wanted[id] = true
        if not self.components[id] then
            local class = Components.find(id)
            if class then self.components[id] = class:new{ home = self } end
        end
    end
    for id, child in pairs(self.components) do
        if not wanted[id] then
            child:destroy()
            self.components[id] = nil
        end
    end
end

--- 首次显示时按真实屏幕高度生成默认分页并落盘。
---@param self BookHome 当前视图或布局实例
---@param ctx table 构建上下文，提供尺寸、数据源和桌面宿主
---@param body_h number 扣除固定控件后的正文高度，单位像素
local function ensureLayout(self, ctx, body_h)
    if not Components.needsLayout() then return end
    local placements = Components.widgets()
    local inner_w, inner_h, gap = Layout.metrics(ctx.width, body_h)
    local ranges = {}
    for _i, place in ipairs(placements) do
        local comp = self.components[place.id]
        if comp then
            local range = comp:heightRange(ctx, { width = inner_w, height = inner_h })
            range.id = place.id
            ranges[#ranges + 1] = range
        end
    end
    local packs = Layout.paginate(ranges, inner_h, gap)
    local next_list = Widgets.applyPacks(placements, packs)
    Components.saveWidgets(next_list)
end

--- 移除指定组件的摆放记录并刷新首页布局。
---@param self BookHome 当前视图或布局实例
---@param id string 组件、分页或数据源的标识
local function deleteWidget(self, id)
    local list = Components.widgets()
    if #list <= 1 then return end
    local out = {}
    for _i, item in ipairs(list) do
        if item.id ~= id then out[#out + 1] = item end
    end
    Components.saveWidgets(out)
    redraw(self)
end

--- 定位组件的摆放记录、所在页的有序记录及其页内序号。
---@param list table 组件摆放记录
---@param id string 组件标识
---@return table|nil item, table page_items, integer|nil pos
local function locate(list, id)
    local item = Widgets.find(list, id)
    if not item then return nil, {}, nil end
    local page_items = Widgets.onPage(list, item.page)
    for i, row in ipairs(page_items) do
        if row.id == id then return item, page_items, i end
    end
    return item, page_items, nil
end

--- 在当前页内移动指定组件，保存顺序并重新排版。
---@param self BookHome 当前视图或布局实例
---@param id string 组件、分页或数据源的标识
---@param delta number 相对于当前位置的偏移量
local function moveInPage(self, id, delta)
    local list = Components.widgets()
    local _item, page_items, pos = locate(list, id)
    if not pos then return end
    local next_pos = pos + delta
    if next_pos < 1 or next_pos > #page_items then return end
    local a, b = page_items[pos], page_items[next_pos]
    a.order, b.order = b.order, a.order
    Components.saveWidgets(list)
    redraw(self)
end

--- 把指定组件移到相邻页，保存分页位置并重新排版。
---@param self BookHome 当前视图或布局实例
---@param id string 组件、分页或数据源的标识
---@param delta_page number 目标页相对于当前页的偏移量
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
    redraw(self)
end

--- 根据当前组件位置生成可用的页内移动和跨页移动操作。
---@param self BookHome 当前视图或布局实例
---@param id string 组件、分页或数据源的标识
local function showMove(self, id)
    local item, page_items, pos = locate(Components.widgets(), id)
    if not item then return end
    Edit.showMoveDialog({
        can_up = pos ~= nil and pos > 1,
        can_down = pos ~= nil and pos < #page_items,
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
            redraw(self)
        end,
    })
end

--- 尚未摆上首页的已注册组件。
---@return table[] candidates { id, label } 列表，按注册顺序
local function unplaced()
    local placed = {}
    for _i, item in ipairs(Components.widgets()) do placed[item.id] = true end
    local candidates = {}
    for _i, comp in ipairs(Components.list()) do
        if not placed[comp.id] then
            candidates[#candidates + 1] = { id = comp.id, label = comp.label }
        end
    end
    return candidates
end

--- 未上屏的组件均可添加；当前页放不下则落到新页。
---@param self BookHome 当前视图或布局实例
---@param body_h number 扣除固定控件后的正文高度，单位像素
---@param width number 目标宽度，单位像素
local function showAdd(self, body_h, width)
    local candidates = unplaced()
    if #candidates == 0 then return end
    Edit.showAddDialog(candidates, function(id)
        local next_list = Components.widgets()
        local ctx = self.desktop:ctx()
        local inner_w, inner_h, gap = Layout.metrics(width, body_h)
        local page_items = Widgets.onPage(next_list, self.page)
        local mins = {}
        for _i, place in ipairs(page_items) do
            local spec = self.components[place.id] or Components.find(place.id)
            if spec then
                local range = spec:heightRange(ctx, { width = inner_w, height = inner_h })
                range.placement = place
                mins[#mins + 1] = Layout.packHeight(range)
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
        redraw(self)
    end)
end

--- 编辑态翻页条中间：「添加」（还有没摆上的组件时）+「完成」。
---@param self BookHome
---@param body_h number 正文高
---@param w number 宽
---@return table
local function editActions(self, body_h, w)
    local row = HorizontalGroup:new{ align = "center" }
    if #unplaced() > 0 then
        row[#row + 1] = Button:new{ icon = "add", text = _("添加"), callback = function() showAdd(self, body_h, w) end }
        row[#row + 1] = HorizontalSpan:new{ width = Theme.px(Theme.current().space.sm) }
    end
    row[#row + 1] = Button:new{ icon = "check", text = _("完成"), variant = "primary",
        callback = function() self:exitEdit() end }
    return row
end

--- 按当前尺寸和配置拼装整页：组件区 + 翻页条；非编辑态长按进编辑。
---@param self BookHome
---@return table
local function assemble(self)
    local ctx = self.desktop:ctx()
    local t = Theme.current()
    local w, h = ctx.width, ctx.height
    local body_h = math.max(1, h - Theme.px(t.control.height))
    ensureLayout(self, ctx, body_h)

    local wrap
    if self.editing then
        wrap = function(widget, meta)
            local child = self.components[meta.id] --[[@as table]]
            local open = child.showSettings
            return Edit.wrap(widget, meta, {
                on_delete = function(id) deleteWidget(self, id) end,
                on_move = function(id) showMove(self, id) end,
                on_height = function(id, range, placement) showHeight(self, id, range, placement) end,
                on_settings = type(open) == "function" and function() open(child, self.desktop) end or nil,
            })
        end
    end

    local body
    body, self.page, self.pages, self.visible = Layout.build(ctx, self.components, self.page, {
        body_height = body_h,
        wrap = wrap,
    })
    local holder = InputContainer:new{
        dimen = Geom:new{ w = w, h = h },
        Box:new{
            style = { bg = t.color.page },
            width = w,
            height = h,
            VerticalGroup:new{
                align = "left",
                body,
                -- 只有一页且非编辑态：不显示翻页条，留同高占位，正文高度不变、不跳动
                (self.pages <= 1 and not self.editing) and VerticalSpan:new{ width = Theme.px(t.control.height) }
                    or Pager.widget({
                    width = w,
                    page = self.page,
                    pages = self.pages,
                    dots = true,
                    center = self.editing and editActions(self, body_h, w) or nil,
                    on_prev = function() self:turn(-1) end,
                    on_next = function() self:turn(1) end,
                }),
            },
        },
    }
    if not self.editing then
        holder.ges_events = {
            HoldHomeEdit = { GestureRange:new{ ges = "hold", range = function() return holder.dimen end } },
        }
        holder.onHoldHomeEdit = function()
            self:enterEdit()
            return true
        end
    end
    return holder
end

--- 把首页页码限制在有效范围内，页码变化时重建。
---@param delta number 相对于当前位置的偏移量
function Home:turn(delta)
    local next_page = math.max(1, math.min(self.pages, self.page + delta))
    if next_page == self.page then return end
    self.page = next_page
    redraw(self)
end

function Home:enterEdit()
    if self.editing then return end
    self.editing = true
    redraw(self)
    -- 组件上叠网点遮罩，局刷会留残影。
    local desktop = self.desktop
    if desktop.active and desktop.tab == "home" and require("utils.settings").get("ui").mesh_mask then
        require("ui/uimanager"):setDirty(desktop, "full")
    end
end

--- 退出编辑模式；每个编辑动作已各自落盘。
function Home:exitEdit()
    if not self.editing then return end
    self.editing = false
    redraw(self)
end

--- 同步组件实例、新建整页，再按可见性驱动组件 activate / deactivate。
---@return table
function Home:updateView()
    self:sync()
    local widget = assemble(self)
    applyVisible(self)
    return widget
end

--- switchTab 传 changed（布尔）且紧接着整页重建，这里只记前台；
--- Desktop:activate（系统唤醒 / 关书回桌面）不传参，重建一次让读最近书架等组件拿到新数据。
---@param changed boolean|nil
function Home:activate(changed)
    self.active = true
    if changed == nil then redraw(self) end
end

--- 退出编辑态，然后暂停全部组件。
function Home:deactivate()
    self.active = false
    self.editing = false
    applyVisible(self)
end

function Home:destroy()
    self.active = false
    for _id, child in pairs(self.components) do child:destroy() end
    self.components = {}
    self.editing = false
end

--- 布局设置 / 换源 / 首页刷新 / 详情变化重建整页；滑动翻页；其余事件转给组件。
---@param event string|table 父组件转发的事件名称或事件对象
---@param payload any 与事件一起传入的数据
function Home:onEvent(event, payload)
    if event == "home_changed" then
        redraw(self)
        return
    end
    if event == "swipe" then
        if self.editing then return end
        if payload.direction == "west" then
            self:turn(1)
        elseif payload.direction == "east" then
            self:turn(-1)
        end
        return
    end
    broadcast(self, "onEvent", event, payload)
    -- 换源后 Desktop 必然 switchTab("home") 重建首页，这里再建一次是白做。
    if event == "home_refresh" or event == "detail_dirty" then redraw(self) end
end

return Home
