--[[--
阅读页快捷面板动作服务。

@module koplugin.book.features.panel.reader
--]]

require("l10n").apply()

local ActionList = require("features.panel.action_list")
local Registry = require("features.panel.actions.registry")

---@class BookQuickPanelReader
---@field options fun(): BookQuickPanelOption[]
---@field enabledCount fun(): number
---@field setEnabled fun(id: string, enabled: boolean)
---@field move fun(id: string, delta: number)
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

local list = ActionList.create("reader", "quick_panel_reader_actions", Registry.readerOrder)

--- 生成阅读页快捷面板设置项。
---@return BookQuickPanelOption[]
function ReaderPanel.options()
    return list.options()
end

--- 当前启用的阅读页动作数量。
---@return number
function ReaderPanel.enabledCount()
    return #list.ids()
end

ReaderPanel.setEnabled = list.setEnabled
ReaderPanel.move = list.move

--- 生成阅读页动作列表，并计算可用和激活态。
---@param ui table|nil
---@return BookQuickPanelReaderAction[]
function ReaderPanel.actions(ui)
    local ctx = { ui = ui }
    local result = {}
    for _idx, id in ipairs(list.ids()) do
        local action = Registry.get(id)
        if action and Registry.available(action, ctx) then
            local active = Registry.active(action, ctx)
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

--- 执行阅读页动作；未注册或当前不可用返回 false。
---@param id string
---@param ui table|nil
---@param opts BookQuickPanelExecuteOpts|nil
---@return boolean
function ReaderPanel.executeAction(id, ui, opts)
    local action = Registry.get(id)
    local ctx = { ui = ui }
    if not Registry.available(action, ctx) then return false end
    ---@cast action BookQuickPanelAction
    Registry.execute(action, ctx, opts)
    return true
end

---@type BookQuickPanelReader
return ReaderPanel
