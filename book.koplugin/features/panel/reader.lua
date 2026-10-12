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
---@field swap fun(a: string, b: string)
---@field actions fun(ui: table|nil): BookQuickPanelMenuItem[]
---@field executeAction fun(id: string, ui: table|nil, opts: BookQuickPanelExecuteOpts|nil): boolean

local ReaderPanel = {}

local list = ActionList.create("reader", "quick_panel_reader_actions", Registry.readerOrder)

--- 当前启用的阅读页动作数量。
---@return number
function ReaderPanel.enabledCount()
    return #list.ids()
end

ReaderPanel.options = list.options
ReaderPanel.setEnabled = list.setEnabled
ReaderPanel.move = list.move
ReaderPanel.swap = list.swap

--- 生成阅读页动作列表，并计算可用和激活态。
---@param ui table|nil
---@return BookQuickPanelMenuItem[]
function ReaderPanel.actions(ui)
    return list.actions({ ui = ui })
end

--- 执行阅读页动作；未注册或当前不可用返回 false。
---@param id string
---@param ui table|nil
---@param opts BookQuickPanelExecuteOpts|nil
---@return boolean
function ReaderPanel.executeAction(id, ui, opts)
    return list.execute(id, { ui = ui }, opts)
end

---@type BookQuickPanelReader
return ReaderPanel
