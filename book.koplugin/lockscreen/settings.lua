--[[--
锁屏设置：模式读写与 KOReader screensaver_* 接管。

@module koplugin.book.lockscreen.settings
--]]

local MoonSettings = require("utils.settings")
local lfs = require("libs/libkoreader-lfs")

local M = {}

---@return string|nil
function M.mode()
    return MoonSettings.get().lock_screen
end

---@param mode string|nil
---@return nil
function M.setMode(mode)
    local c = MoonSettings.get()
    c.lock_screen = mode or "ko"
    MoonSettings.save()
end

---@param path string
---@return nil
function M.applyCover(path)
    local attr = lfs.attributes(path)
    if not attr or attr.mode ~= "file" or (attr.size or 0) == 0 then
        G_reader_settings:saveSetting("screensaver_show_message", true)
        return
    end
    G_reader_settings:saveSetting("screensaver_type", "document_cover")
    G_reader_settings:saveSetting("screensaver_document_cover", path)
    G_reader_settings:saveSetting("screensaver_show_message", false)
end

---@return nil
function M.clearCover()
    G_reader_settings:saveSetting("screensaver_type", "disable")
    G_reader_settings:delSetting("screensaver_document_cover")
    G_reader_settings:saveSetting("screensaver_show_message", true)
end

---@return string|nil
function M.savedDay()
    return MoonSettings.get().lock_screen_day
end

---@param day string|nil
---@return nil
function M.setSavedDay(day)
    local c = MoonSettings.get()
    c.lock_screen_day = day
    MoonSettings.save()
end

return M
