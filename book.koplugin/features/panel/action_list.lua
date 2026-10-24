--[[-- 快捷面板动作列表：持久化、去重、排序。
@module koplugin.book.features.panel.action_list
--]]

local MoonSettings = require("utils.settings")
local Registry = require("features.panel.actions.registry")

---@class BookQuickPanelActionList
---@field ids fun(): string[]
---@field setEnabled fun(id: string, enabled: boolean)
---@field move fun(id: string, delta: number)
---@field swap fun(a: string, b: string)
---@field actions fun(ctx: BookQuickPanelContext): BookQuickPanelMenuItem[]
---@field execute fun(id: string, ctx: BookQuickPanelContext, opts: BookQuickPanelExecuteOpts|nil): boolean
---@field hold fun(id: string, ctx: BookQuickPanelContext, opts: BookQuickPanelExecuteOpts|nil): boolean
---@field options fun(): BookQuickPanelOption[]

--- 设置页没有 ReaderUI：可用性一律按 ctx.ui = nil 判断。
local SETTINGS_CTX = {}

---@param scope "desktop"|"reader"
---@param settings_key string
---@param order_fn fun(): string[] 设置页展示顺序；配置缺失时即启用列表
---@return BookQuickPanelActionList
local function create(scope, settings_key, order_fn)
    ---@return string[]
    local function ids()
        local raw = MoonSettings.get("features.panel")[settings_key]
        if type(raw) ~= "table" then raw = order_fn() end
        local seen, result = {}, {}
        for _idx, id in ipairs(raw) do
            local action = Registry.get(id)
            if action and action.scope == scope and not seen[id] then
                seen[id] = true
                result[#result + 1] = id
            end
        end
        return result
    end

    ---@param new_ids string[]
    local function save(new_ids)
        local settings = MoonSettings.get("features.panel")
        settings[settings_key] = new_ids
        MoonSettings.save("features.panel", settings)
    end

    ---@param id string
    ---@param enabled boolean
    local function setEnabled(id, enabled)
        local action = Registry.get(id)
        if not action or action.scope ~= scope then return end
        if enabled and not Registry.available(action, SETTINGS_CTX) then return end
        local current, found = ids(), nil
        for i, current_id in ipairs(current) do
            if current_id == id then
                found = i
                break
            end
        end
        if enabled and not found then
            current[#current + 1] = id
        elseif not enabled and found then
            table.remove(current, found)
        end
        save(current)
    end

    ---@param id string
    ---@param delta number
    local function move(id, delta)
        local current = ids()
        for i, current_id in ipairs(current) do
            if current_id == id then
                local target = math.max(1, math.min(#current, i + delta))
                if target ~= i then
                    table.insert(current, target, table.remove(current, i))
                    save(current)
                end
                return
            end
        end
    end

    --- 按 id 互换两项。面板编辑只看得见可用项，邻居必须由调用方按可见顺序给出，
    --- 不能用 move：完整列表里夹着当前不可用的项，±1 会换到看不见的位置上。
    ---@param a string
    ---@param b string
    local function swap(a, b)
        local current = ids()
        local i, j
        for k, current_id in ipairs(current) do
            if current_id == a then i = k elseif current_id == b then j = k end
        end
        if not i or not j then return end
        current[i], current[j] = current[j], current[i]
        save(current)
    end

    --- 面板按钮：启用且当前可用的动作，带激活态。
    ---@param ctx BookQuickPanelContext
    ---@return BookQuickPanelMenuItem[]
    local function actions(ctx)
        local result = {}
        for _idx, id in ipairs(ids()) do
            local action = Registry.get(id)
            if Registry.available(action, ctx) then
                ---@cast action BookQuickPanelAction
                local active = Registry.active(action, ctx)
                result[#result + 1] = {
                    id = id,
                    title = action.title,
                    icon = active and action.active_icon or action.icon,
                    active = active,
                    hold = action.hold ~= nil,
                }
            end
        end
        return result
    end

    --- 执行动作；未注册或当前不可用返回 false。
    ---@param id string
    ---@param ctx BookQuickPanelContext
    ---@param opts BookQuickPanelExecuteOpts|nil
    ---@return boolean
    local function execute(id, ctx, opts)
        local action = Registry.get(id)
        if not Registry.available(action, ctx) then return false end
        ---@cast action BookQuickPanelAction
        Registry.execute(action, ctx, opts)
        return true
    end

    --- 长按动作；未注册、不可用或没有 hold 返回 false。
    ---@param id string
    ---@param ctx BookQuickPanelContext
    ---@param opts BookQuickPanelExecuteOpts|nil
    ---@return boolean
    local function hold(id, ctx, opts)
        local action = Registry.get(id)
        if not Registry.available(action, ctx) or not action.hold then return false end
        Registry.executeHold(action, ctx, opts)
        return true
    end

    ---@return BookQuickPanelOption[]
    local function options()
        local enabled = {}
        for position, action_id in ipairs(ids()) do
            enabled[action_id] = position
        end
        local result = {}
        for _idx, action_id in ipairs(order_fn()) do
            local action = Registry.get(action_id)
            if action then
                result[#result + 1] = {
                    id = action_id,
                    scope = scope,
                    title = action.title,
                    icon = action.icon,
                    enabled = enabled[action_id] ~= nil,
                    position = enabled[action_id],
                    available = Registry.available(action, SETTINGS_CTX),
                }
            end
        end
        return result
    end

    return {
        ids = ids,
        setEnabled = setEnabled,
        move = move,
        swap = swap,
        actions = actions,
        execute = execute,
        hold = hold,
        options = options,
    }
end

return { create = create }
