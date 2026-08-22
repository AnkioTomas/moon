--[[--
多选列表：点按只切换 Material 勾选图标、不关闭。
on_toggle(value, checked, item, selected) 每次切换触发（selected 为当前全部勾选值列表）；
最终结果在 close_callback 里读取。

@module koplugin.book.ui.components.popup.multi
--]]

local List = require("ui.components.popup.list")

local Multi = {}

--- 把调用方 items 规范成 Menu 可用结构。
--- ctx: { refresh, on_toggle }；opts 同 Multi.open。
---@param items table|nil
---@param ctx table
---@param opts table
---@return table out, number max_state_w
function Multi.normalize(items, ctx, opts)
    local out = {}
    local raws = {} -- 可选中的原始项（selectedValues 的数据源）
    local max_state_w = 0

    --- 当前全部勾选值（on_toggle 第 4 参）。
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

    --- 勾选框 state，可与 icon/image/widget 并存。
    ---@param raw table
    ---@param image_only boolean
    ---@return table state, number state_w
    local function buildState(raw, image_only)
        local inner, inner_w = List.buildInner(raw, image_only, opts)
        return List.withChoiceMark(inner, inner_w, raw.checked == true, true, opts)
    end

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
            raws[#raws + 1] = raw
            local state, state_w = buildState(raw, image_only)
            item.state = state
            max_state_w = math.max(max_state_w, state_w)

            if raw.enabled ~= false then
                local value = raw.value
                local user_cb = raw.callback
                -- 点按只切换勾选并重绘当前页，不关闭
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
            end
            table.insert(out, item)
        end
    end
    return out, max_state_w
end

--- 打开多选列表（opts 见 popup.lua 头注释；无需 select_mode）。
---@param opts table|nil
---@return table
function Multi.open(opts)
    return List.openList(opts or {}, Multi.normalize)
end

return Multi
