--[[--
Popup 列表的共享底座：Menu 构造与项内嵌控件，不含单选/多选语义。
单选见 popup/single.lua，多选见 popup/multi.lua。

@module koplugin.book.ui.components.popup.list
--]]

local HorizontalGroup = require("ui/widget/horizontalgroup")
local Button = require("ui/widget/button")
local HorizontalSpan = require("ui/widget/horizontalspan")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local UI = require("ui.components.bookui")
local Image = require("ui.components.image")
local Icon = require("ui.components.icon")

local List = {}

--- 图片是否顶替文案。
---@param raw table
---@return boolean
function List.imageOnly(raw)
    return raw.image and (raw.text == nil or raw.text == false or raw.image_only)
end

--- 项内嵌控件：widget > image > icon。
---@param raw table
---@param image_only boolean
---@param opts table
---@return table|nil inner, number inner_w
function List.buildInner(raw, image_only, opts)
    local icon_sz = opts.icon_size or UI.iconSz()
    local image_sz = opts.image_size or UI.sz(40)
    if raw.widget then
        return raw.widget, tonumber(raw.widget_w) or (raw.widget.getSize and raw.widget:getSize().w) or image_sz
    end
    if raw.image then
        local iw = tonumber(raw.image_w) or (image_only and (opts.image_w or image_sz)) or icon_sz
        local ih = tonumber(raw.image_h) or (image_only and (opts.image_h or image_sz)) or icon_sz
        local inner = Image.widget{
            src = raw.image,
            width = iw,
            height = ih,
            alpha = raw.alpha ~= false,
            headers = raw.headers or opts.headers,
            fallback = raw.fallback,
        }
        return inner, inner and iw or 0
    end
    if raw.icon then
        local inner = Icon.widget{ name = raw.icon }
        return inner, inner and icon_sz or 0
    end
    return nil, 0
end

--- Menu 项基础字段（禁用项在此收口：无回调、置灰）。
---@param raw table
---@param image_only boolean
---@return table
function List.baseItem(raw, image_only)
    local item = {
        text = image_only and "" or (raw.text or tostring(raw.value or "")),
        select_enabled = raw.enabled ~= false,
        bold = nil,
        dim = raw.dim or raw.enabled == false,
        mandatory = raw.mandatory,
        keep_menu_open = raw.keep_menu_open,
    }
    if raw.enabled == false then
        item.enabled = false
        item.select_enabled = false
    end
    return item
end

--- 前置 Material 选择图标（multi=checkbox，否则 radio），可与 inner 组合。
---@param inner table|nil
---@param inner_w number
---@param selected boolean
---@param multi boolean
---@param opts table
---@return table state, number state_w
function List.withChoiceMark(inner, inner_w, selected, multi, opts)
    local icon_sz = opts.icon_size or UI.iconSz()
    local gap = UI.sz(6)
    local cm = Icon.widget{ name = multi and (selected and "check_box" or "check_box_outline_blank")
        or (selected and "radio_button_checked" or "radio_button_unchecked") }
    if not inner then
        return cm, icon_sz
    end
    return HorizontalGroup:new{
        align = "center",
        cm,
        HorizontalSpan:new{ width = gap },
        inner,
    }, icon_sz + gap + inner_w
end

--- 底部 Tab 栏（仅全屏列表）：完整 pager 行之下再加一行全宽等分 Tab。
--- bt: { tabs = { { id = ..., text = ... }, ... }, active = 当前 id, on_tab = fun(id) }
--- 给 menu 挂 setBottomTabActive(id) 供调用方切选中态。
---@param menu table
---@param bt table
local function attachBottomTabs(menu, bt)
    local ok_center, CenterContainer = pcall(require, "ui/widget/container/centercontainer")
    local Geom = ok_center and require("ui/geometry") or nil
    local ok, BottomBar = pcall(require, "ui.components.bottombar")
    local function buildBar()
        if not ok then
            local bar = HorizontalGroup:new{ align = "center" }
            local cell_w = math.floor(menu.inner_dimen.w / math.max(1, #(bt.tabs or {})))
            for _, tab in ipairs(bt.tabs or {}) do
                local id = tab.id
                bar[#bar + 1] = Button:new{
                    text = tab.text, width = cell_w, bordersize = 0,
                    text_font_bold = id == bt.active,
                    callback = function() if id ~= bt.active and bt.on_tab then bt.on_tab(id) end end,
                    show_parent = menu,
                }
            end
            return bar
        end
        return BottomBar.build(bt.tabs or {}, bt.active, function(id)
            if id ~= bt.active and bt.on_tab then bt.on_tab(id) end
        end, menu)
    end
    local bar = buildBar()
    local bar_h = bar:getSize().h
    -- footer 是底对齐的 BottomContainer：子件换成「pager 在上、Tab 栏在下」的竖排。
    -- menu → FrameContainer → OverlapGroup(content_group, page_return, footer)
    local pager = menu.page_info
    if ok_center then
        pager = CenterContainer:new{
            dimen = Geom:new{ w = menu.inner_dimen.w, h = menu.page_info:getSize().h },
            menu.page_info,
        }
    end
    local stack = VerticalGroup:new{ align = "left", pager, bar }
    menu[1][1][3][1] = stack
    -- Menu 底部只预留了 pager 高度（menu.lua _recalculateDimen）：重算时补扣 Tab 栏高度
    local orig = menu._recalculateDimen
    menu._recalculateDimen = function(self, no_recalculate_dimen)
        orig(self, no_recalculate_dimen)
        if not no_recalculate_dimen then
            self.available_height = self.available_height - bar_h
            self.item_dimen.h = math.floor(self.available_height / self.perpage)
        end
    end
    --- 切换选中 Tab 并重绘页脚。
    ---@param self table
    ---@param id any
    menu.setBottomTabActive = function(self, id)
        bt.active = id
        stack[2] = buildBar()
        stack:resetLayout()
        UIManager:setDirty(self, "ui")
    end
    menu:updateItems() -- 触发一次全量重算，让上面的补扣生效
end

--- 全屏选项列表（翻页，不滚动）。normalize 由 single/multi 注入。
--- opts: title / subtitle / items / current / on_select / on_toggle
---       / close_callback / icon_size / image_size / centered / bottom_tabs …
---@param opts table|nil
---@param normalize fun(items: table|nil, ctx: table, opts: table): table, number, number|nil
---@return table
function List.openList(opts, normalize)
    opts = opts or {}
    local holder = { menu = nil }
    --- 关闭当前 list 菜单（仅关闭，不触发回调——Menu 的 close_callback 会处理）。
    local function close()
        if holder.menu then
            UIManager:close(holder.menu)
            holder.menu = nil
        end
    end
    --- 重绘当前页（多选勾选切换用）。
    local function refresh()
        if holder.menu then
            holder.menu:updateItems(nil, true)
        end
    end

    local items, state_w, current_idx
    if opts.raw then
        items = opts.items or {}
        state_w = opts.state_w or 0
        current_idx = opts.current_idx
    else
        items, state_w, current_idx = normalize(opts.items, {
            close = close,
            refresh = refresh,
            on_select = opts.on_select,
            on_toggle = opts.on_toggle,
        }, opts)
    end
    if current_idx then
        items.current = current_idx -- Menu init 自动跳到该页并把当前项加粗
    end

    local centered_height
    local screen
    if opts.centered then
        screen = require("device").screen
        local max_height = screen:getHeight() - UI.sz(32)
        centered_height = math.min(max_height, UI.sz(72 + #items * 52))
    end
    local menu = Menu:new{
        title = opts.title or "",
        subtitle = opts.subtitle,
        item_table = items,
        is_borderless = not opts.centered,
        is_popout = opts.centered == true,
        covers_fullscreen = opts.centered ~= true,
        width = opts.centered and (opts.width or UI.sz(420)) or opts.width,
        height = opts.centered and (opts.height or centered_height) or opts.height,
        title_bar_left_icon = opts.title_icon,
        items_font_size = UI.menuFontSize(),
        title_shrink_font_to_fit = true,
        state_w = (state_w and state_w > 0) and state_w or nil,
        items_per_page = opts.centered and math.max(1, #items) or nil,
        close_callback = function()
            holder.menu = nil
            if opts.close_callback then
                opts.close_callback()
            end
        end,
    }
    holder.menu = menu

    if opts.bottom_tabs then
        attachBottomTabs(menu, opts.bottom_tabs)
    end

    if opts.centered then
        menu.page_info_text:setText("")
        menu.page_info_text:hide()
        menu.page_info_left_chev:hide()
        menu.page_info_right_chev:hide()
        menu.page_info_first_chev:hide()
        menu.page_info_last_chev:hide()
        menu.page_return_arrow:hide()
        UIManager:show(menu, nil, nil,
            math.floor((screen:getWidth() - menu.dimen.w) / 2),
            math.floor((screen:getHeight() - menu.dimen.h) / 2))
    else
        UIManager:show(menu)
    end
    return menu
end

return List
