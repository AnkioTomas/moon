--[[--
锁屏背景：custom.png / 必应日图 / 最近在读书籍封面；否则由渲染器铺纯色。

@module koplugin.book.lockscreen.background
--]]

local lfs = require("libs/libkoreader-lfs")
local Request = require("http.request")
local Paths = require("utils.paths")
local MoonSettings = require("utils.settings")

local M = {}

---@param path string
---@return boolean 文件存在且大小超过最小有效阈值
local function fileOk(path)
    local attr = lfs.attributes(path)
    return attr and attr.mode == "file" and (attr.size or 0) > 8
end

---@return string 自定义背景图片路径
function M.customPath()
    return Paths.screensaverDir() .. "/custom.png"
end

---@return string 必应背景缓存路径
function M.bingPath()
    return Paths.screensaverDir() .. "/bing.jpg"
end

--- 最近在读书籍封面（本地缓存）；没有则 nil。
---@return string|nil
function M.coverPath()
    local ok, Context = pcall(require, "lockscreen.context")
    if not ok or not Context or not Context.currentBook then
        return nil
    end
    local book = Context.currentBook()
    local path = book and book.cover
    return fileOk(path) and path or nil
end

--- 返回当前可用背景，不触网。
---@return string|nil
function M.current()
    local mode = MoonSettings.get().lock_screen_background or "bing"
    if mode == "custom" then
        return fileOk(M.customPath()) and M.customPath() or nil
    end
    if mode == "cover" then
        return M.coverPath()
    end
    if mode == "bing" and fileOk(M.bingPath()) then
        return M.bingPath()
    end
    return nil
end

--- 确保背景可用。自定义 / 封面永不触网；必应按日更新，失败时保留旧图。
---@param cb fun(path: string|nil)
---@return table|nil 可取消的下载任务；本地命中时返回 nil
function M.ensure(cb)
    local cancelled = false
    local c = MoonSettings.get()
    local mode = c.lock_screen_background or "bing"
    if mode == "none" then
        cb(nil)
        return nil
    end
    if mode == "custom" then
        cb(fileOk(M.customPath()) and M.customPath() or nil)
        return nil
    end
    if mode == "cover" then
        cb(M.coverPath())
        return nil
    end
    local today = os.date("%Y-%m-%d")
    local cached = M.bingPath()
    if c.lock_screen_bing_day == today and fileOk(cached) then
        cb(cached)
        return nil
    end
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isOnline() then
        cb(fileOk(cached) and cached or nil)
        return nil
    end
    Paths.ensureScreensaverDir()
    local tmp = cached .. ".part"
    local request_job = Request.download({
        url = "https://api.ankio.net/bing",
        method = "GET",
        allow_redirects = true,
        timeout = 60,
    }, tmp, function(ok)
        if cancelled then
            os.remove(tmp)
            return
        end
        if ok and os.rename(tmp, cached) then
            c.lock_screen_bing_day = today
            MoonSettings.save()
            cb(cached)
        else
            os.remove(tmp)
            cb(fileOk(cached) and cached or nil)
        end
    end)
    return {
        cancel = function()
            cancelled = true
            if request_job and request_job.cancel then
                request_job.cancel()
            end
        end,
    }
end

return M
