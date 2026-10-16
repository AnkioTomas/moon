--[[--
KOReader 只认带 main.lua 的插件目录；扩展本身不需要任何插件钩子，月读扫描旁边的 moon_source.lua。
--]]
local WidgetContainer = require("ui/widget/container/widgetcontainer")

return WidgetContainer:extend{
    name = "moonwidget_demo",
    is_doc_only = false,
}
