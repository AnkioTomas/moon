--[[--
阅读页动作与接线。

原生顶部菜单 Tab、Aa 菜单注入（features.panel）、上下栏和侧栏都由 features
在 onReaderReady 安装。

@module koplugin.book.reader.page
--]]

local Event = require("ui/event")

---@class BookReader
local Reader = {}

--- 阅读页 Create：挂原生菜单注入与阅读状态条。
---@param plugin table
function Reader.onCreate(plugin)
    local ui = plugin and plugin.ui
    if not ui or ui._book_reader_attached then return end
    ui._book_reader_attached = true

    -- 面板、顶底栏和侧栏要在首绘之前装上。
    require("utils.extension").emit("reader.ready", plugin)
    if ui.handleEvent then
        ui:handleEvent(Event:new("UpdatePos"))
    end
    require("reader.highlight_menu").install(ui)
    require("reader.book_notes").install(ui)
    require("reader.selection").install(ui)
end

return Reader
