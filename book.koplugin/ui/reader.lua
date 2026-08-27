--[[--
阅读页动作与接线。

原生顶部菜单 Tab 和 Aa 菜单注入由 ui.panel.native 负责；阅读面板动作在
ui.panel.reader，本模块只挂载阅读状态条。

@module koplugin.book.ui.reader
--]]

local Event = require("ui/event")
local UIManager = require("ui/uimanager")

local Reader = {}

--- 当前阅读页的图标动作；原生 Tab 每次重绘都重新取状态。
---@param ui table|nil
---@return table[]
function Reader.actions(ui)
    return require("ui.panel.reader").actions(ui)
end

--- 执行顶部图标动作。
---@param id string
---@param ui table|nil
---@param opts table|nil
---@return boolean
function Reader.executeAction(id, ui, opts)
    return require("ui.panel.reader").executeAction(id, ui, opts)
end

--- 给当前 ReaderUI 安装原生菜单注入和阅读状态条。
---@param plugin table
function Reader.attach(plugin)
    local ui = plugin and plugin.ui
    if not ui or ui._book_reader_attached then return end
    ui._book_reader_attached = true

    require("ui.panel.native").install(ui, { reader = true })
    if ui.view and ui.view.registerViewModule then
        local bars = require("ui.reader.bars")
        ui.view:registerViewModule("book_bars", bars)
        bars:startClock()
    end
    -- Book 自绘上下进度条替换 KOReader 原生底部状态栏/进度条。
    local footer = ui.view and ui.view.footer
    if footer and footer.disableFooter then
        pcall(footer.disableFooter, footer)
    end
    require("ui.reader.bars").applyInsets(ui)
    if ui.handleEvent then
        ui:handleEvent(Event:new("UpdatePos"))
    end
    require("lockscreen.init").refreshInBackground(true)
    require("xray.marks").install(ui)
end

---@param plugin table
function Reader.refresh(plugin)
    local ui = plugin and plugin.ui
    if ui then UIManager:setDirty(ui.dialog, "ui") end
    local LockScreen = require("lockscreen.init")
    local force = LockScreen.needsLiveRefresh and LockScreen.needsLiveRefresh()
    LockScreen.refreshInBackground(force)
end

return Reader
