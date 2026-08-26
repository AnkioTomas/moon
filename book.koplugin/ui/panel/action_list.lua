--[[-- 快捷面板动作列表：持久化、去重、排序。
@module koplugin.book.ui.panel.action_list
--]]

local MoonSettings = require("utils.settings")
local Registry = require("ui.panel.actions.registry")

---@class BookQuickPanelActionList
---@field ids fun(): string[]
---@field save fun(ids: string[]): void
---@field setEnabled fun(id: string, enabled: boolean): void
---@field move fun(id: string, delta: number): void
---@field options fun(order_fn: fun(): string[]): BookQuickPanelOption[]

---@param scope "desktop"|"reader"
---@param settings_key string
---@param default_ids string[]|fun(): string[]
---@param opts { before_read: (fun(): void)|nil, can_enable: (fun(action: BookQuickPanelAction): boolean)|nil, settings_available: (fun(action: BookQuickPanelAction): boolean)|nil }|nil
---@return BookQuickPanelActionList
local function create(scope, settings_key, default_ids, opts)
    opts = opts or {}

    ---@return string[]
    local function ids()
        if opts.before_read then opts.before_read() end
        local configured = MoonSettings.get()[settings_key]
        if type(configured) ~= "table" then
            configured = type(default_ids) == "function" and default_ids() or default_ids
        end
        local seen, result = {}, {}
        for _, id in ipairs(configured) do
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
        local settings = MoonSettings.get()
        settings[settings_key] = new_ids
        MoonSettings.save(settings)
    end

    ---@param id string
    ---@param enabled boolean
    local function setEnabled(id, enabled)
        local action = Registry.get(id)
        if not action or action.scope ~= scope then return end
        if enabled and opts.can_enable and not opts.can_enable(action) then return end
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
                    current[i], current[target] = current[target], current[i]
                    save(current)
                end
                return
            end
        end
    end

    ---@param order_fn fun(): string[]
    ---@return BookQuickPanelOption[]
    local function options(order_fn)
        local enabled = {}
        for position, action_id in ipairs(ids()) do
            enabled[action_id] = position
        end
        local result = {}
        for _, action_id in ipairs(order_fn()) do
            local action = Registry.get(action_id)
            local available = opts.settings_available
                and opts.settings_available(action)
                or Registry.available(action)
            result[#result + 1] = {
                id = action_id,
                scope = scope,
                title = action.title,
                icon = action.icon,
                enabled = enabled[action_id] ~= nil,
                position = enabled[action_id],
                available = available,
            }
        end
        return result
    end

    return {
        ids = ids,
        save = save,
        setEnabled = setEnabled,
        move = move,
        options = options,
    }
end

return { create = create }
