--[[--
阅读页快捷面板动作服务。

@module koplugin.book.ui.panel.reader
--]]

require("l10n").apply()

local ActionList = require("ui.panel.action_list")
local Registry = require("ui.panel.actions.registry")

---@class BookQuickPanelReader
---@field options fun(): BookQuickPanelOption[]
---@field enabledCount fun(): number
---@field setEnabled fun(id: string, enabled: boolean): void
---@field move fun(id: string, delta: number): void
---@field actions fun(ui: table|nil): BookQuickPanelReaderAction[]
---@field executeAction fun(id: string, ui: table|nil, opts: { close: fun()|nil, refresh: fun()|nil }|nil): boolean

local ReaderPanel = {}

--- 阅读页快捷面板按钮数据。
---@class BookQuickPanelReaderAction
---@field id string
---@field title string
---@field icon string
---@field active boolean
---@field enabled boolean
---@field keep_open boolean

--- 设置页无 ReaderUI，用 nil ui 判断动作是否可配置。
---@param action BookQuickPanelAction
---@return boolean
local function settingsAvailable(action)
    return Registry.available(action, { ui = nil })
end

local list = ActionList.create("reader", "quick_panel_reader_actions", Registry.readerOrder, {
    can_enable = settingsAvailable,
    settings_available = settingsAvailable,
})

--- 生成阅读页快捷面板设置项。
---@return BookQuickPanelOption[]
function ReaderPanel.options()
    return list.options(Registry.readerOrder)
end

--- 当前启用的阅读页动作数量。
---@return number
function ReaderPanel.enabledCount()
    return #list.ids()
end

--- 启用或停用某个阅读页动作。
---@param id string
---@param enabled boolean
---@return void
function ReaderPanel.setEnabled(id, enabled)
    list.setEnabled(id, enabled)
end

--- 上移或下移某个阅读页动作。
---@param id string
---@param delta number
---@return void
function ReaderPanel.move(id, delta)
    list.move(id, delta)
end

--- 生成阅读页动作列表，并计算可用和激活态。
---@param ui table|nil
---@return BookQuickPanelReaderAction[]
function ReaderPanel.actions(ui)
    local ctx = { ui = ui }
    local result = {}
    for _, id in ipairs(list.ids()) do
        local action = Registry.get(id)
        if Registry.available(action, ctx) then
            local active = Registry.active(id, action, ctx)
            result[#result + 1] = {
                id = id,
                title = action.title,
                icon = active and action.active_icon or action.icon,
                active = active,
                enabled = true,
                keep_open = action.keep_open == true,
            }
        end
    end
    return result
end

--- 执行阅读页动作，按动作配置决定是否关闭或刷新面板。
---@param id string
---@param ui table|nil
---@param opts { close: fun()|nil, refresh: fun()|nil }|nil
---@return boolean
function ReaderPanel.executeAction(id, ui, opts)
    local action = Registry.get(id)
    local ctx = { ui = ui }
    if not action or not Registry.available(action, ctx) then
        return false
    end
    opts = opts or {}
    if not action.keep_open and opts.close then opts.close() end
    action.run(ctx)
    if action.keep_open and opts.refresh then opts.refresh() end
    return true
end

---@type BookQuickPanelReader
return ReaderPanel
