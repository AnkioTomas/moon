--[[--
锁屏显示：可选接管 KOReader screensaver。

  "ko"   — 跟随系统（恢复接管前的 screensaver_*）
  "myrl" — 摸鱼日报：下载 PNG 后设 document_cover，并关掉自带「Sleeping」提示

日报按天更新：lock_screen_myrl_day 不是今天（或文件缺失）即重下。
图片落盘：.moon/cache/screensaver/myrl.png
screensaver_* 在选中 / 启动 / 下载成功时就写好：休眠时 KOReader 已经建好锁屏
widget（Screensaver:setup 早于 Suspend 事件），那时再写对本次锁屏无效。

@module koplugin.book.lockscreen
--]]

local Device = require("device")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local Request = require("http.request")
local Paths = require("utils.paths")
local MoonSettings = require("utils.settings")
local _ = require("gettext")

local MODE_KO = "ko"
local MODE_MYRL = "myrl"

local M = {
    MODE_KO = MODE_KO,
    MODE_MYRL = MODE_MYRL,
}

--- 在飞下载；切模式时取消。
local _job

---@return string
local function dir()
    return Paths.cacheDir() .. "/screensaver"
end

--- 摸鱼日报缓存路径（固定 .png，API 返回 image/png）。
---@return string
function M.imagePath()
    return dir() .. "/myrl.png"
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
function M.mode()
    local m = MoonSettings.get().lock_screen
    if m == MODE_MYRL then
        return MODE_MYRL
    end
    return MODE_KO
end

---@param mode string|nil
---@return string
function M.label(mode)
    if (mode or M.mode()) == MODE_MYRL then
        return _("摸鱼日报")
    end
    return _("跟随 KOReader")
end

---@return boolean
local function fileOk(path)
    local attr = lfs.attributes(path)
    return attr ~= nil and attr.mode == "file" and (attr.size or 0) > 0
end

--- 写入 KOReader 锁屏配置：document_cover 指向摸鱼日报，并关掉自带的「Sleeping」提示文字。
---@param path string
local function applyCover(path)
    G_reader_settings:saveSetting("screensaver_type", "document_cover")
    G_reader_settings:saveSetting("screensaver_document_cover", path)
    G_reader_settings:saveSetting("screensaver_show_message", false)
end

--- 首次接管时备份用户原锁屏设置（只备份一次，直到恢复）。
local function backupIfNeeded()
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
local function restorePrev()
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

local function cancelJob()
    if _job and _job.cancel then
        _job.cancel()
    end
    _job = nil
end

--- 网络已可用时在后台刷新；离线直接返回，等待 NetworkConnected 再试。
--- Request.download 走 Turbo，不阻塞 UI。
function M.refreshInBackground()
    if M.mode() ~= MODE_MYRL or _job then
        return
    end
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isOnline() then
        return
    end
    M.refresh()
end

--- 下载摸鱼日报并接管锁屏；今日已下且文件还在则直接复用。
--- 失败不改模式，等下次 onResume / NetworkConnected 重试。
---@param cb fun(ok: boolean, err: any)|nil
function M.refresh(cb)
    -- 等联网（wifi 弹窗）期间用户可能已切回跟随
    if M.mode() ~= MODE_MYRL then
        return
    end

    local path = M.imagePath()
    local day = os.date("%Y-%m-%d")
    local c = MoonSettings.get()
    if c.lock_screen_myrl_day == day and fileOk(path) then
        applyCover(path)
        if cb then
            cb(true)
        end
        return
    end

    cancelJob()
    Paths.ensureCacheRoot()
    lfs.mkdir(dir())

    -- 下 tmp 再改名：失败/半截文件不会顶掉上一张好图
    local tmp = path .. ".part"
    _job = Request.download({
        url = apiUrl(),
        method = "GET",
        timeout = 60,
    }, tmp, function(ok, err)
        _job = nil
        if not ok then -- tmp 由 writeResponseToFile 失败时自删
            logger.warn("book.lockscreen download failed:", err)
            if cb then
                cb(false, err)
            end
            return
        end
        if not os.rename(tmp, path) then
            os.remove(tmp)
            if cb then
                cb(false, "rename failed")
            end
            return
        end
        c.lock_screen_myrl_day = day
        MoonSettings.save()
        applyCover(path)
        if cb then
            cb(true)
        end
    end)
end

--- 切换模式：只写状态，落盘不依赖网络。
--- 选 myrl 后由调用方在联网时机调 M.refresh。
---@param mode string
function M.setMode(mode)
    cancelJob()
    local c = MoonSettings.get()
    if mode ~= MODE_MYRL then
        if M.mode() == MODE_MYRL then
            restorePrev()
        end
        c.lock_screen = MODE_KO
        MoonSettings.save()
        return
    end

    backupIfNeeded()
    c.lock_screen = MODE_MYRL
    -- 重选即重下：清今日标记
    c.lock_screen_myrl_day = nil
    MoonSettings.save()
end

--- 插件启动：有缓存则立刻接管；缺失或过期则下一拍后台下载。
function M.bootstrap()
    if M.mode() ~= MODE_MYRL then
        return
    end
    local path = M.imagePath()
    if fileOk(path) then
        applyCover(path)
    end
    UIManager:nextTick(function()
        M.refreshInBackground()
    end)
end

return M
