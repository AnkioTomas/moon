--[[--
单选列表：点按即关闭（项上 keep_menu_open 除外），回调 on_select(value, item)。
opts.current = value 或项上 checked=true 标记当前项并跳页；
opts.choice_icons=true 显示 Material 单选图标。

@module koplugin.book.ui.components.popup.single
--]]

local List = require("ui.components.popup.list")

local Single = {}

--- 把调用方 items 规范成 Menu 可用结构。
--- ctx: { close, on_select }；opts 同 Single.open。
---@param items table|nil
---@param ctx table
---@param opts table
---@return table out, number max_state_w, number|nil current_idx
function Single.normalize(items, ctx, opts)
    local out = {}
    local max_state_w = 0
    local current_idx

    for _, raw in ipairs(items or {}) do
        if type(raw) == "string" then
            raw = { text = raw, value = raw }
        end
        -- 保留带 submenu 的原生 Menu 项（字体列表等）
        if raw.sub_item_table or raw.sub_item_table_func then
            table.insert(out, raw)
        else
            local image_only = List.imageOnly(raw)
            local item = List.baseItem(raw, image_only)
            local state, state_w = List.buildInner(raw, image_only, opts)
            if opts.choice_icons then
                local selected = raw.checked == true or (opts.current ~= nil and raw.value == opts.current)
                state, state_w = List.withChoiceMark(state, state_w, selected, false, opts)
            end
            item.state = state
            max_state_w = math.max(max_state_w, state_w)

            if raw.enabled ~= false then
                local value = raw.value
                local user_cb = raw.callback
                item.callback = function()
                    if not raw.keep_menu_open then
                        ctx.close()
                    end
                    if user_cb then
                        user_cb()
                    elseif ctx.on_select then
                        ctx.on_select(value, raw)
                    end
                end
            end
            table.insert(out, item)
            -- 当前项：显式 current 值优先，其次项上 checked=true
            if not current_idx
                and ((opts.current ~= nil and raw.value ~= nil and raw.value == opts.current)
                    or raw.checked == true) then
                current_idx = #out
            end
        end
    end
    return out, max_state_w, current_idx
end

--- 打开单选列表（opts 见 popup.lua 头注释；无需 select_mode）。
---@param opts table|nil
---@return table
function Single.open(opts)
    return List.openList(opts or {}, Single.normalize)
end

return Single
