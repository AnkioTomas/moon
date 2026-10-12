--[[--
KOReader 只认带 main.lua 的插件目录，返回 nil 会被当成加载失败、不进已启用列表，
月读也就扫不到旁边的 moon_source.lua。书源本身不需要任何插件钩子。
--]]
local WidgetContainer = require("ui/widget/container/widgetcontainer")

return WidgetContainer:extend{
    name = "moonsource_bookorbit",
    is_doc_only = false,
}
