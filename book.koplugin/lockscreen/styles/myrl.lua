--[[--
锁屏样式：摸鱼日报。

日报按天更新：dayKey 不是今天（或文件缺失）即重下。
图片落盘：.moon/cache/screensaver/myrl.png

@module koplugin.book.lockscreen.styles.myrl
--]]

local Device = require("device")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local Request = require("http.request")
local Paths = require("utils.paths")
local _ = require("gettext")

---@class LockScreenStyle
local M = {
    id = "myrl",
    label = _("摸鱼日报"),
}

--- 摸鱼日报缓存路径（固定 .png，API 返回 image/png）。
---@return string
function M.path()
    return Paths.cacheDir() .. "/screensaver/myrl.png"
end

--- 竖屏宽高（锁屏会强制竖屏显示图片）。
---@return number, number
local function portraitSize()
    local Screen = Device.screen
    local w, h = Screen:getWidth(), Screen:getHeight()
    if w > h then
        return h, w
    end
    return w, h
end

---@return string
local function apiUrl()
    local w, h = portraitSize()
    return string.format(
        "https://api.ankio.net/myrl?ink=1&width=%d&height=%d",
        w, h
    )
end

---@return string
function M.dayKey()
    return os.date("%Y-%m-%d")
end

--- 下载今日摸鱼日报。
--- 下 tmp 再改名：失败/半截文件不会顶掉上一张好图。
---@param cb fun(ok: boolean, err: any)
---@return table|nil 可 cancel 的在飞任务
function M.fetch(cb)
    local path = M.path()
    Paths.ensureCacheRoot()
    lfs.mkdir(Paths.cacheDir() .. "/screensaver")
    local tmp = path .. ".part"
    return Request.download({
        url = apiUrl(),
        method = "GET",
        timeout = 60,
    }, tmp, function(ok, err)
        if not ok then -- tmp 由 writeResponseToFile 失败时自删
            logger.warn("book.lockscreen myrl download failed:", err)
            cb(false, err)
            return
        end
        if not os.rename(tmp, path) then
            os.remove(tmp)
            cb(false, "rename failed")
            return
        end
        cb(true)
    end)
end

return M
