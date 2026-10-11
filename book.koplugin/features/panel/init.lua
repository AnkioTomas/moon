--[[--
快捷面板：把桌面 / 阅读面板 Tab 注入 KOReader 原生顶部菜单。

实现在 `native.lua`；桌面其它模块（顶栏、夜间模式、设置页）直接 require 子模块，不经这里。

@module koplugin.book.features.panel
--]]

local Panel = {}

---@param plugin BookPlugin
function Panel.onCreate(plugin)
    require("features.panel.native").onCreate(plugin.ui)
end

---@param plugin BookPlugin
function Panel.onReaderReady(plugin)
    require("features.panel.native").onCreate(plugin.ui, { reader = true })
end

return Panel
