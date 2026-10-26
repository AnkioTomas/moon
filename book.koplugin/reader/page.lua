--[[--
阅读页动作与接线。

原生顶部菜单 Tab、Aa 菜单注入（features.panel）、上下栏和侧栏都由 features
在 onReaderReady 安装。

@module koplugin.book.reader.page
--]]

local Event = require("ui/event")

---@class BookReader
local Reader = {}

--- 边距选项原生带 hide_on_apply：收起设置面板并弹「Margins set to」信息框。
--- 开关关闭（默认）时去掉它，面板留着，改动直接重排渲染，不弹提示。
local function applyMarginPopup()
    local popup = require("utils.settings").get("reader").margin_popup == true
    for _idx, tab in ipairs(require("ui/data/creoptions") --[[@as { options: table[] }[] ]]) do
        for _idx2, option in ipairs(tab.options) do
            if option.name and option.name:find("page_margin", 1, true) then
                option.hide_on_apply = popup or nil
            end
        end
    end
end

--- 阅读页 Create：挂原生菜单注入与阅读状态条。
---@param plugin table
function Reader.onCreate(plugin)
    local ui = plugin and plugin.ui
    if not ui or ui._book_reader_attached then return end
    ui._book_reader_attached = true
    applyMarginPopup()

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
