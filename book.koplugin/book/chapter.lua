--[[--
按章阅读会话（兼容入口）。

实现已迁至 chapters/；本文件仅 re-export。
注意必须写 chapters.init：KOReader 插件路径只有 `<plugin>/?.lua`，
没有 `?/init.lua`，裸 require("chapters") 在真机上找不到目录模块。

@module koplugin.book.book.chapter
--]]

return require("chapters.init")
