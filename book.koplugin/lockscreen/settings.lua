--[[--
锁屏设置：组合锁屏与 KOReader screensaver 接管。

@module koplugin.book.lockscreen.settings
--]]

local lfs = require("libs/libkoreader-lfs")

local M = {}

--- 将有效锁屏图片交给 KOReader 的 document_cover screensaver。
---@param path string|nil
---@return nil
function M.applyCover(path)
    if type(path) ~= "string" or path == "" then
        G_reader_settings:saveSetting("screensaver_show_message", true)
        return
    end
    local attr = lfs.attributes(path)
    if not attr or attr.mode ~= "file" or (attr.size or 0) == 0 then
        G_reader_settings:saveSetting("screensaver_show_message", true)
        return
    end
    G_reader_settings:saveSetting("screensaver_type", "document_cover")
    G_reader_settings:saveSetting("screensaver_document_cover", path)
    G_reader_settings:saveSetting("screensaver_show_message", false)
end

--- 清除插件对系统 screensaver 的接管。
---@return nil
function M.clearCover()
    G_reader_settings:saveSetting("screensaver_type", "disable")
    G_reader_settings:delSetting("screensaver_document_cover")
    G_reader_settings:saveSetting("screensaver_show_message", true)
end

return M
