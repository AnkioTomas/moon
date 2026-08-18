--[[--
弹出层选项。

  Popup.list   — 列表（支持居中单选/多选与 Material 选择图标）
  Popup.sheet  — 居中动作表（ButtonDialog，适合少量动作）
  Popup.spin   — 数值增减（SpinWidget）
  Popup.directory — 插件内目录选择（左上取消，右上确认）

布局：

  list 单选/多选（可居中）       sheet（居中）              directory
  +------------------+          +------------------+       +-------------+         +-------------+
  | title            |          | title            |       |   title     |         |   title     |
  | subtitle         |          | subtitle         |       |-------------|         |  [-] N [+]  |
  |------------------|          |------------------|       |  action 1   |         |  cancel  ok |
  | [i] item     ›   |          | [✓] item     ›   |       |  action 2   |         +-------------+
  | [i] item（加粗） |          | [▢] item     ›   |       |  cancel     |
  | …                |          | …                |       +-------------+
  | Page N of M      |          | Page N of M      |
  +------------------+          +------------------+

items 统一形状：
  { text = "...", callback = fn }           -- 点按执行并关闭（多选时不关闭，回调拿到 checked）
  { text = "...", value = x }               -- 配合 on_select(value, item) / on_toggle
  { text = "...", icon = "home" }           -- Material Icons 名（字体图标）
  { text = "...", image = "https://..." }   -- 预览图（可非正方形，见 image_w/h）
  { text = "...", widget = w, widget_w = n } -- 自定义 state 控件（字体预览等）
  { image = "https://...", image_only = true } -- 文案替换为图
  { text = "...", enabled = false }         -- 不可点（置灰；多选时勾选框同样置灰）
  { text = "...", checked = true }          -- 选中态：使用 Material 选择图标
  { text = "...", mandatory = "..." }       -- 右侧弱化小字（当前值/状态提示）
  { text = "...", dim = true }              -- 置灰；选项文字不加粗
  { text = "...", separator = true }        -- sheet 里作为分隔（空行）

list 选择语义：
  select_mode = "single"（默认）点按即关闭；opts.current = value 或项上 checked=true
    opts.choice_icons=true 显示 Material 单选图标；centered=true 使用居中 Menu。
  select_mode = "multi" 点按只切换 Material 勾选图标、不关闭；on_toggle(value, checked, item, selected)
    每次切换触发（selected 为当前全部勾选值列表）；最终结果在 close_callback 里读取。

@module koplugin.book.ui.components.popup
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local Menu = require("ui/widget/menu")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local UI = require("ui.components.bookui")
local Image = require("ui.components.image")
local Icon = require("ui.components.icon")

local Popup = {}

--- 勾选框与 state 控件之间的间距。
---@return number
local function checkGap()
    return UI.sz(6)
end

--- 把调用方 items 规范成 Menu 可用结构。
--- ctx: { close, refresh, on_select, on_toggle }；opts 同 Popup.list。
---@param items table|nil
---@param ctx table
---@param opts table|nil
---@return table out, number max_state_w, number|nil current_idx
local function normalizeItems(items, ctx, opts)
    opts = opts or {}
    local icon_sz = opts.icon_size or UI.iconSz()
    local image_sz = opts.image_size or UI.sz(40)
    local multi = opts.select_mode == "multi"
    local choice_icons = multi or opts.choice_icons == true
    local out = {}
    local raws = {} -- 可选中的原始项（selectedValues 的数据源）
    local max_state_w = 0
    local current_idx

    --- 当前全部勾选值（multi 的 on_toggle 第 4 参）。
    ---@return table
    local function selectedValues()
        local t = {}
        for _, r in ipairs(raws) do
            if r.checked and r.value ~= nil then
                t[#t + 1] = r.value
            end
        end
        return t
    end

    --- 构造 state 控件：multi 前置勾选框，可与 icon/image/widget 并存。
    ---@param raw table
    ---@param image_only boolean
    ---@return table|nil state, number state_w
    local function buildState(raw, image_only)
        local inner, inner_w
        if raw.widget then
            inner = raw.widget
            inner_w = tonumber(raw.widget_w) or (raw.widget.getSize and raw.widget:getSize().w) or image_sz
        elseif raw.image then
            local iw = tonumber(raw.image_w) or (image_only and (opts.image_w or image_sz)) or icon_sz
            local ih = tonumber(raw.image_h) or (image_only and (opts.image_h or image_sz)) or icon_sz
            inner = Image.widget{
                src = raw.image,
                width = iw,
                height = ih,
                alpha = raw.alpha ~= false,
                headers = raw.headers or opts.headers,
                fallback = raw.fallback,
            }
            inner_w = inner and iw or 0
        elseif raw.icon then
            inner = Icon.widget{ name = raw.icon }
            inner_w = inner and icon_sz or 0
        end
        if not choice_icons then
            return inner, inner_w or 0
        end
        local selected = raw.checked == true or (not multi and opts.current ~= nil and raw.value == opts.current)
        local cm = Icon.widget{ name = multi and (selected and "check_box" or "check_box_outline_blank")
            or (selected and "radio_button_checked" or "radio_button_unchecked") }
        local cm_w = icon_sz
        if not inner then
            return cm, cm_w
        end
        return HorizontalGroup:new{
            align = "center",
            cm,
            HorizontalSpan:new{ width = checkGap() },
            inner,
        }, cm_w + checkGap() + inner_w
    end

    for _, raw in ipairs(items or {}) do
        if type(raw) == "string" then
            raw = { text = raw, value = raw }
        end
        -- 保留带 submenu 的原生 Menu 项（字体列表等）
        if raw.sub_item_table or raw.sub_item_table_func then
            table.insert(out, raw)
        else
            -- image：可替换文案；icon：小图标；widget：自定义 state（如字体样张）
            local image_only = raw.image and (raw.text == nil or raw.text == false or raw.image_only)
            local item = {
                text = image_only and "" or (raw.text or tostring(raw.value or "")),
                select_enabled = raw.enabled ~= false,
                bold = nil,
                dim = raw.dim or raw.enabled == false,
                mandatory = raw.mandatory,
            }
            raws[#raws + 1] = raw
            local state, state_w = buildState(raw, image_only)
            item.state = state
            max_state_w = math.max(max_state_w, state_w or 0)

            if raw.enabled == false then
                item.enabled = false
                item.select_enabled = false
            else
                local value = raw.value
                local user_cb = raw.callback
                if multi then
                    -- 多选：点按只切换勾选并重绘当前页，不关闭
                    item.callback = function()
                        raw.checked = not raw.checked
                        item.state = buildState(raw, image_only)
                        ctx.refresh()
                        if user_cb then
                            user_cb(raw.checked, raw)
                        end
                        if ctx.on_toggle then
                            ctx.on_toggle(value, raw.checked, raw, selectedValues())
                        end
                    end
                else
                    item.callback = function()
                        ctx.close()
                        if user_cb then
                            user_cb()
                        elseif ctx.on_select then
                            ctx.on_select(value, raw)
                        end
                    end
                end
            end
            table.insert(out, item)
            -- 单选当前项：显式 current 值优先，其次项上 checked=true
            if not multi and not current_idx then
                if (opts.current ~= nil and raw.value ~= nil and raw.value == opts.current)
                    or raw.checked == true then
                    current_idx = #out
                end
            end
        end
    end
    return out, max_state_w, current_idx
end

--- 全屏选项列表（翻页，不滚动）。
--- opts: title / subtitle / items / select_mode("single"|"multi") / current
---       / on_select / on_toggle / close_callback / icon_size / image_size …
---@param opts table|nil
---@return table
function Popup.list(opts)
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
        items, state_w, current_idx = normalizeItems(opts.items, {
            close = close,
            refresh = refresh,
            on_select = opts.on_select,
            on_toggle = opts.on_toggle,
        }, opts)
    end
    if current_idx then
        items.current = current_idx -- Menu init 自动跳到该页并把当前项加粗
    end

    local menu = Menu:new{
        title = opts.title or "",
        subtitle = opts.subtitle,
        item_table = items,
        is_borderless = not opts.centered,
        is_popout = opts.centered == true,
        covers_fullscreen = opts.centered ~= true,
        width = opts.centered and (opts.width or UI.sz(420)) or opts.width,
        height = opts.centered and (opts.height or UI.sz(600)) or opts.height,
        title_bar_left_icon = opts.title_icon,
        items_font_size = UI.menuFontSize(),
        title_shrink_font_to_fit = true,
        state_w = (state_w and state_w > 0) and state_w or nil,
        close_callback = function()
            holder.menu = nil
            if opts.close_callback then
                opts.close_callback()
            end
        end,
    }
    holder.menu = menu

    UIManager:show(menu)
    return menu
end

--- 居中动作表（少量选项）。
---@param opts table|nil
---@return table
function Popup.sheet(opts)
    opts = opts or {}
    local holder = { dialog = nil }
    --- 关闭当前 sheet 对话框。
    local function close()
        if holder.dialog then
            UIManager:close(holder.dialog)
            holder.dialog = nil
        end
        if opts.close_callback then
            opts.close_callback()
        end
    end

    local rows = {}
    for _, raw in ipairs(opts.items or {}) do
        if type(raw) == "string" then
            raw = { text = raw, value = raw }
        end
        if raw.separator then
            -- ButtonDialog 用空行不自然；跳过，调用方自己分组
        else
            local value = raw.value
            local user_cb = raw.callback
            local enabled = raw.enabled
            table.insert(rows, {{
                text = raw.text or tostring(value or ""),
                enabled = enabled ~= false,
                callback = function()
                    close()
                    if user_cb then
                        user_cb()
                    elseif opts.on_select then
                        opts.on_select(value, raw)
                    end
                end,
            }})
        end
    end

    local dialog = ButtonDialog:new{
        title = opts.title,
        title_align = "center",
        use_info_style = false,
        buttons = rows,
        tap_close_callback = function()
            holder.dialog = nil
            if opts.close_callback then
                opts.close_callback()
            end
        end,
    }
    holder.dialog = dialog
    UIManager:show(dialog)
    return dialog
end

--- 数值增减框（SpinWidget）。
---@param opts table|nil
---@return table
function Popup.spin(opts)
    opts = opts or {}
    local holder = { spin = nil }
    local spin = SpinWidget:new{
        title_text = opts.title or "",
        info_text = opts.info_text,
        value = opts.value or 0,
        value_min = opts.value_min or 0,
        value_max = opts.value_max or 100,
        value_step = opts.value_step or 1,
        value_hold_step = opts.value_hold_step,
        value_table = opts.value_table,
        value_index = opts.value_index,
        precision = opts.precision,
        unit = opts.unit,
        wrap = opts.wrap,
        ok_always_enabled = opts.ok_always_enabled,
        default_value = opts.default_value,
        default_text = opts.default_text,
        cancel_text = opts.cancel_text,
        ok_text = opts.ok_text,
        callback = function(widget)
            if opts.callback then
                opts.callback(widget)
            end
        end,
        cancel_callback = opts.cancel_callback,
        close_callback = function()
            holder.spin = nil
            if opts.close_callback then
                opts.close_callback()
            end
        end,
    }
    holder.spin = spin
    UIManager:show(spin)
    return spin
end

--- 更新已打开的 list 菜单内容（异步加载筛选结果时用）。
--- 不关闭菜单；opts 可带 select_mode / on_toggle / current / subtitle，
--- 单选给了 current 时会跳到当前项所在页。
---@param menu table|nil
---@param title string|nil
---@param items table|nil
---@param on_select fun(value: any, item: table)|nil
---@param opts table|nil
function Popup.setListItems(menu, title, items, on_select, opts)
    if not menu then
        return
    end
    opts = opts or {}
    -- setListItems 不应关闭菜单，只需更新内容（选中不关闭是既有行为）
    local normalized, state_w, current_idx = normalizeItems(items, {
        close = function() end,
        refresh = function()
            menu:updateItems(nil, true)
        end,
        on_select = on_select,
        on_toggle = opts.on_toggle,
    }, opts)
    if current_idx then
        normalized.current = current_idx
    end
    if state_w and state_w > 0 then
        menu.state_w = state_w
    end
    if menu.switchItemTable then
        menu:switchItemTable(title or menu.title, normalized, current_idx, nil, opts.subtitle)
        UIManager:setDirty(menu, "ui")
    end
end

--- 目录选择器。只在给定根目录下浏览；左上取消，右上确认当前目录。
---@param opts table { path: string, root: string|nil, title: string|nil, on_select: fun(path: string)|nil, on_cancel: fun()|nil }
---@return table
function Popup.directory(opts)
    opts = opts or {}
    local lfs = require("libs/libkoreader-lfs")
    local TitleBar = require("ui/widget/titlebar")
    local root = opts.root or "/"
    local function isWithin(path)
        return path == root or root == "/" or path:sub(1, #root + 1) == root .. "/"
    end
    local function parent(path)
        if path == root then return path end
        return path:match("^(.*)/[^/]+$") or root
    end
    local function open(path)
        local holder = { menu = nil }
        local function close(cancelled)
            if holder.menu then UIManager:close(holder.menu) end
            if cancelled and opts.on_cancel then opts.on_cancel() end
        end
        local title_bar = TitleBar:new{
            fullscreen = "true", align = "center", title = opts.title or "选择目录", subtitle = path,
            left_icon = "exit", left_icon_tap_callback = function() close(true) end,
            right_icon = "check", right_icon_tap_callback = function()
                close(false)
                if opts.on_select then opts.on_select(path) end
            end,
        }
        local entries = {}
        if path ~= root then
            entries[#entries + 1] = { text = "..", icon = "arrow_upward", callback = function()
                close(false)
                open(parent(path))
            end }
        end
        local names = {}
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then
                local full = path == "/" and "/" .. name or path .. "/" .. name
                if lfs.attributes(full, "mode") == "directory" then names[#names + 1] = name end
            end
        end
        table.sort(names)
        for _, name in ipairs(names) do
            entries[#entries + 1] = { text = name, icon = "folder", callback = function()
                close(false)
                open(path == "/" and "/" .. name or path .. "/" .. name)
            end }
        end
        local directory_items, state_w = normalizeItems(entries, { close = function() close(false) end, refresh = function() end }, {})
        holder.menu = Menu:new{
            custom_title_bar = title_bar, title = opts.title or "选择目录", subtitle = path,
            item_table = directory_items, state_w = state_w,
            is_borderless = true, is_popout = false, covers_fullscreen = true,
            items_font_size = UI.menuFontSize(), title_shrink_font_to_fit = true,
        }
        UIManager:show(holder.menu)
        return holder.menu
    end
    local path = opts.path or root
    if not isWithin(path) or lfs.attributes(path, "mode") ~= "directory" then path = root end
    return open(path)
end

return Popup
