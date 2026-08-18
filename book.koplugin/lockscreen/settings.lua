--[[--
锁屏设置：模式读写与 KOReader screensaver_* 配置。

不保留接管前的 KOReader 屏保配置。跟随 KOReader 的固定默认行为是：
不设置屏保图片，显示锁屏信息。
screensaver_* 在选中 / 启动 / 下载成功时就写好：休眠时 KOReader 已经建好锁屏
widget（Screensaver:setup 早于 Suspend 事件），那时再写对本次锁屏无效。

@module koplugin.book.lockscreen.settings
--]]

local MoonSettings = require("utils.settings")
local lfs = require("libs/libkoreader-lfs")

local M = {}

---@return string|nil style id；"ko"/nil = 跟随 KOReader
function M.mode()
    return MoonSettings.get().lock_screen
end

---@param mode string|nil 样式 id；nil 表示跟随 KOReader
---@return nil
function M.setMode(mode)
    local c = MoonSettings.get()
    -- nil 只代表旧配置缺失；用户明确选择「跟随」必须持久化为 ko，
    -- 否则下次启动会被默认 myrl 重新补上。
    c.lock_screen = mode or "ko"
    MoonSettings.save()
end

--- 写入 KOReader 锁屏配置；图片不存在时恢复默认锁屏配置。
---@param path string 有效图片路径
---@return nil
function M.applyCover(path)
    local attr = lfs.attributes(path)
    if not attr or attr.mode ~= "file" or (attr.size or 0) == 0 then
        -- 保留上一张可用锁屏图，只恢复 KOReader 的准备中提示。
        G_reader_settings:saveSetting("screensaver_show_message", true)
        return
    end
    G_reader_settings:saveSetting("screensaver_type", "document_cover")
    G_reader_settings:saveSetting("screensaver_document_cover", path)
    G_reader_settings:saveSetting("screensaver_show_message", false)
end

--- 新图片尚未生成时撤下插件旧封面，显示 KOReader 默认透明提示态。
---@return nil
function M.clearCover()
    G_reader_settings:saveSetting("screensaver_type", "disable")
    G_reader_settings:delSetting("screensaver_document_cover")
    G_reader_settings:saveSetting("screensaver_show_message", true)
end

---@return string|nil 成功生成样式的日期标记
function M.savedDay()
    return MoonSettings.get().lock_screen_day
end

---@param day string|nil 当前样式成功生成的日期标记
---@return nil
function M.setSavedDay(day)
    local c = MoonSettings.get()
    c.lock_screen_day = day
    MoonSettings.save()
end

return M
