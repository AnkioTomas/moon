--[[--
弹出层选项。

  Popup.list   — 全屏列表（Menu，自带 Page of，适合筛选项/长列表）
  Popup.sheet  — 居中动作表（ButtonDialog，适合少量动作）

items 统一形状：
  { text = "...", callback = fn }           -- 点按执行并关闭
  { text = "...", value = x }               -- 配合 on_select(value, item)
  { text = "...", enabled = false }         -- 不可点
  { text = "...", separator = true }        -- sheet 里作为分隔（空行）

@module koplugin.book.ui.components.popup
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local UI = require("ui.components.bookui")

local Popup = {}

local function normalizeItems(items, close_fn, on_select)
    local out = {}
    for _, raw in ipairs(items or {}) do
        if type(raw) == "string" then
            raw = { text = raw, value = raw }
        end
        -- 保留带 submenu 的原生 Menu 项（字体列表等）
        if raw.sub_item_table or raw.sub_item_table_func then
            table.insert(out, raw)
        else
            local item = {
                text = raw.text or tostring(raw.value or ""),
                enabled = raw.enabled,
            }
            if raw.enabled == false then
                item.enabled = false
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
            table.insert(out, item)
        end
    end
    return out
end

--- 全屏选项列表（翻页，不滚动）
-- @param opts.title string
-- @param opts.items table
-- @param opts.on_select function|nil  -- function(value, item)
-- @param opts.close_callback function|nil
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

    local items = opts.raw and (opts.items or {}) or normalizeItems(opts.items, close, opts.on_select)
    local menu = Menu:new{
        title = opts.title or "",
        item_table = items,
        is_borderless = true,
        is_popout = false,
        covers_fullscreen = true,
        items_font_size = UI.menuFontSize(),
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

--- 更新已打开的 list 菜单内容（异步加载筛选结果时用）
function Popup.setListItems(menu, title, items, on_select)
    if not menu then
        return
    end
    local function close()
        UIManager:close(menu)
    end
    local normalized = normalizeItems(items, close, on_select)
    if menu.switchItemTable then
        menu:switchItemTable(title or menu.title, normalized)
        UIManager:setDirty(menu, "ui")
    end
end

return Popup
