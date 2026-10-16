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

-- 扩展点登记（features 加载器 require 本模块时执行一次；见 utils/extension.lua）。
local Ext = require("utils.extension")
Ext.add("quickpanel.show", function(scope) return require("features.panel.native").show(scope) end)
Ext.add("topbar.light_percent", function(kind) return require("features.panel.desktop").lightPercent(kind) end)

return Panel
