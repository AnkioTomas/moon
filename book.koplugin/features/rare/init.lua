--[[--
生僻字注音：阅读页在生僻字 / 生词上方画拼音或音标。数据是可下载的注音词库（见 catalog、README.md）。

@module koplugin.book.features.rare.init
--]]

local Rare = {}

---@param plugin BookPlugin
function Rare.onReaderReady(plugin)
    require("features.rare.overlay").install(plugin.ui)
end

return Rare
