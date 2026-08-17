--[[--
锁屏设置：模式读写，接管 / 恢复 KOReader screensaver_* 配置。

首次接管时备份用户原锁屏设置（lock_screen_prev_*，只备份一次，直到恢复）；
选回跟随系统或数据损坏时恢复。
screensaver_* 在选中 / 启动 / 下载成功时就写好：休眠时 KOReader 已经建好锁屏
widget（Screensaver:setup 早于 Suspend 事件），那时再写对本次锁屏无效。

@module koplugin.book.lockscreen.settings
--]]

local MoonSettings = require("utils.settings")

local M = {}

---@return string|nil style id；nil = 跟随 KOReader
function M.mode()
    return MoonSettings.get().lock_screen
end

---@param mode string|nil
function M.setMode(mode)
    local c = MoonSettings.get()
    c.lock_screen = mode
    MoonSettings.save()
end

--- 写入 KOReader 锁屏配置：document_cover 指向样式图片，并关掉自带的「Sleeping」提示文字。
---@param path string
function M.applyCover(path)
    G_reader_settings:saveSetting("screensaver_type", "document_cover")
    G_reader_settings:saveSetting("screensaver_document_cover", path)
    G_reader_settings:saveSetting("screensaver_show_message", false)
end

--- 首次接管时备份用户原锁屏设置（只备份一次，直到恢复）。
function M.backupIfNeeded()
    local c = MoonSettings.get()
    if c.lock_screen_prev_type ~= nil then
        return
    end
    c.lock_screen_prev_type = G_reader_settings:readSetting("screensaver_type") or "disable"
    local cover = G_reader_settings:readSetting("screensaver_document_cover")
    c.lock_screen_prev_cover = (type(cover) == "string" and cover ~= "") and cover or ""
    c.lock_screen_prev_show_message = G_reader_settings:readSetting("screensaver_show_message")
    MoonSettings.save()
end

--- 恢复接管前的 screensaver_*。
function M.restorePrev()
    local c = MoonSettings.get()
    local t = c.lock_screen_prev_type
    if type(t) == "string" and t ~= "" then
        G_reader_settings:saveSetting("screensaver_type", t)
    end
    local cover = c.lock_screen_prev_cover
    if type(cover) == "string" and cover ~= "" then
        G_reader_settings:saveSetting("screensaver_document_cover", cover)
    else
        G_reader_settings:delSetting("screensaver_document_cover")
    end
    local show_message = c.lock_screen_prev_show_message
    if show_message ~= nil then
        G_reader_settings:saveSetting("screensaver_show_message", show_message)
    end
    c.lock_screen_prev_type = nil
    c.lock_screen_prev_cover = nil
    c.lock_screen_prev_show_message = nil
    MoonSettings.save()
end

---@return string|nil
function M.savedDay()
    return MoonSettings.get().lock_screen_day
end

---@param day string|nil
function M.setSavedDay(day)
    local c = MoonSettings.get()
    c.lock_screen_day = day
    MoonSettings.save()
end

return M
