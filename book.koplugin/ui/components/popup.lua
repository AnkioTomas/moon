--[[--
弹出层选项。

  Popup.list   — 全屏列表（Menu，自带 Page of；支持 icon / 纯 image）
  Popup.sheet  — 居中动作表（ButtonDialog，适合少量动作）
  Popup.spin   — 数值增减（SpinWidget）

items 统一形状：
  { text = "...", callback = fn }           -- 点按执行并关闭
  { text = "...", value = x }               -- 配合 on_select(value, item)
  { text = "...", icon = "foo.svg" }        -- 左侧图标
  { image = "https://...", value = x }      -- 文案替换为图（省略 text）
  { image = "https://...", headers = {...} } -- 网络图额外请求头
  { text = "...", enabled = false }         -- 不可点
  { text = "...", separator = true }        -- sheet 里作为分隔（空行）

@module koplugin.book.ui.components.popup
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local Menu = require("ui/widget/menu")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local UI = require("ui.components.bookui")
local Image = require("ui.components.image")

local Popup = {}

local function normalizeItems(items, close_fn, on_select, opts)
    opts = opts or {}
    local icon_sz = opts.icon_size or UI.iconSz()
    local image_sz = opts.image_size or UI.sz(40)
    local out = {}
    local max_state_w = 0

    for _, raw in ipairs(items or {}) do
        if type(raw) == "string" then
            raw = { text = raw, value = raw }
        end
        -- 保留带 submenu 的原生 Menu 项（字体列表等）
        if raw.sub_item_table or raw.sub_item_table_func then
            table.insert(out, raw)
        else
            -- image：可替换文案；icon：左侧小图标（无 text 时用 value 作文案）
            local image_only = raw.image and (raw.text == nil or raw.text == false or raw.image_only)
            local src = raw.image or raw.icon
            local item = {
                text = image_only and "" or (raw.text or tostring(raw.value or "")),
                select_enabled = raw.enabled ~= false,
            }
            if raw.enabled == false then
                item.enabled = false
                item.select_enabled = false
            else
                local value = raw.value
                local user_cb = raw.callback
                item.callback = function()
                    close_fn()
                    if user_cb then
                        user_cb()
                    elseif on_select then
                        on_select(value, raw)
                    end
                end
            end
            if src then
                local sz = image_only and image_sz or icon_sz
                local img = Image.widget{
                    src = src,
                    width = sz,
                    height = sz,
                    headers = raw.headers or opts.headers,
                }
                if img then
                    item.state = img
                    max_state_w = math.max(max_state_w, sz)
                end
            end
            table.insert(out, item)
        end
    end
    return out, max_state_w
end

--- 全屏选项列表（翻页，不滚动）
-- @param opts.title string
-- @param opts.items table
-- @param opts.on_select function|nil  -- function(value, item)
-- @param opts.close_callback function|nil
-- @param opts.icon_size number|nil
-- @param opts.image_size number|nil
-- @return menu widget
function Popup.list(opts)
    opts = opts or {}
    local holder = { menu = nil }
    local function close()
        if holder.menu then
            UIManager:close(holder.menu)
            holder.menu = nil
        end
        if opts.close_callback then
            opts.close_callback()
        end
    end

    local items, state_w
    if opts.raw then
        items = opts.items or {}
        state_w = opts.state_w or 0
    else
        items, state_w = normalizeItems(opts.items, close, opts.on_select, opts)
    end

    local menu = Menu:new{
        title = opts.title or "",
        item_table = items,
        is_borderless = true,
        is_popout = false,
        covers_fullscreen = true,
        items_font_size = UI.menuFontSize(),
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

--- 居中动作表（少量选项）
-- @param opts.title string|nil
-- @param opts.items table
-- @param opts.on_select function|nil
-- @param opts.close_callback function|nil
-- @return dialog widget
function Popup.sheet(opts)
    opts = opts or {}
    local holder = { dialog = nil }
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

--- 数值增减框
-- @param opts.title / value / value_min / value_max / value_step / unit / precision
-- @param opts.callback function(spin)  -- 点 Apply 后；spin.value 为新值
-- @param opts.close_callback function|nil
-- @return spin widget
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

--- 更新已打开的 list 菜单内容（异步加载筛选结果时用）
function Popup.setListItems(menu, title, items, on_select, opts)
    if not menu then
        return
    end
    local function close()
        UIManager:close(menu)
    end
    local normalized, state_w = normalizeItems(items, close, on_select, opts)
    if state_w and state_w > 0 then
        menu.state_w = state_w
    end
    if menu.switchItemTable then
        menu:switchItemTable(title or menu.title, normalized)
        UIManager:setDirty(menu, "ui")
    end
end

return Popup
