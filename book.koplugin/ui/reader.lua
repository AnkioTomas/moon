--[[--
阅读页动作与接线。

原生顶部菜单 Tab 和 Aa 菜单注入由 ui.panel.native 负责；阅读面板动作在
ui.panel.reader，本模块只挂载阅读状态条。

@module koplugin.book.ui.reader
--]]

local Event = require("ui/event")
local UIManager = require("ui/uimanager")

---@class BookReader
local Reader = {}

--- 阅读页 Create：挂原生菜单注入与阅读状态条。
---@param plugin table
function Reader.onCreate(plugin)
    local ui = plugin and plugin.ui
    if not ui or ui._book_reader_attached then return end
    ui._book_reader_attached = true

    require("ui.panel.native").onCreate(ui, { reader = true })
    if ui.view and ui.view.registerViewModule then
        local bars = require("ui.reader.bars")
        ui.view:registerViewModule("book_bars", bars)
        -- 点号定义：冒号调用会把模块表当 ui 传进去（安装标记落在模块上，第二本书起
        -- 直接静默跳过、顶底条不再劫持）。
        bars.install(ui)
        bars:startClock()
    end
    if ui.handleEvent then
        ui:handleEvent(Event:new("UpdatePos"))
    end
    require("xray.marks").install(ui)
    require("ui.reader.highlight_menu").install(ui)
    require("ui.reader.selection").install(ui)
end

---@param plugin table
function Reader.refresh(plugin)
    local ui = plugin and plugin.ui
    if ui then UIManager:setDirty(ui.dialog, "ui") end
end

return Reader
