--[[--
AZW3 支持：向 KOReader 注册月读的 AZW3 文档提供者（实现在 `document.lua` / `kf8.lua`）。

@module koplugin.book.features.azw3
--]]

local Azw3 = {}

--- FM / Reader 各调一次；register 自己去重。
function Azw3.onCreate()
    require("features.azw3.document"):register(require("document/documentregistry"))
end

return Azw3
