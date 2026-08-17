--[[--
锁屏显示入口：可选接管 KOReader screensaver。

  "ko"     — 跟随系统（恢复接管前的 screensaver_*）
  其余     — 已注册样式（见 styles/base.lua），下载图片后设 document_cover

对外 API：mode / label / options / imagePath / setMode / refresh /
refreshInBackground / bootstrap。编排（在飞任务取消、按天重下、备份恢复）
收口在这里，样式只管图片（styles/*.lua），设置只管落盘（settings.lua）。

@module koplugin.book.lockscreen
--]]

local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local Styles = require("lockscreen.styles.base")
local Settings = require("lockscreen.settings")
local _ = require("gettext")

local M = {}

--- 在飞下载；切模式时取消。
local _job

--- 当前样式；跟随系统或未注册 id 一律回落到 nil。
---@return table|nil
function M.currentStyle()
    local mode = Settings.mode()
    if mode == nil then
        return nil
    end
    return Styles.find(mode)
end

---@return string ko = 跟随 KOReader；否则为样式 id
function M.mode()
    if M.currentStyle() == nil then
        return "ko"
    end
    return Settings.mode()
end

---@param mode string|nil
---@return string
function M.label(mode)
    local style = mode ~= nil and Styles.find(mode) or M.currentStyle()
    if style then
        return style.label
    end
    return _("跟随 KOReader")
end

--- 设置页单选项：跟随系统 + 全部已注册样式。
---@return {text: string, value: string}[]
function M.options()
    local items = {
        { text = _("跟随 KOReader"), value = "ko" },
    }
    for _, style in ipairs(Styles.styles) do
        table.insert(items, { text = style.label, value = style.id })
    end
    return items
end

--- 当前样式缓存路径；跟随系统时返回 nil。
---@return string|nil
function M.imagePath()
    local style = M.currentStyle()
    return style and style.path() or nil
end

---@return boolean
local function fileOk(path)
    local attr = lfs.attributes(path)
    return attr ~= nil and attr.mode == "file" and (attr.size or 0) > 0
end

local function cancelJob()
    if _job and _job.cancel then
        _job.cancel()
    end
    _job = nil
end

--- 网络已可用时在后台刷新；离线直接返回，等待 NetworkConnected 再试。
--- style.fetch 走 Turbo，不阻塞 UI。
function M.refreshInBackground()
    if M.currentStyle() == nil or _job then
        return
    end
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isOnline() then
        return
    end
    M.refresh()
end

--- 下载样式图片并接管锁屏；今日已下且文件还在则直接复用。
--- 失败不改模式，等下次 onResume / NetworkConnected 重试。
---@param cb fun(ok: boolean, err: any)|nil
function M.refresh(cb)
    -- 等联网（wifi 弹窗）期间用户可能已切回跟随
    local style = M.currentStyle()
    if style == nil then
        return
    end

    local path = style.path()
    local day = style.dayKey and style.dayKey() or nil
    if day ~= nil and Settings.savedDay() == day and fileOk(path) then
        Settings.applyCover(path)
        if cb then
            cb(true)
        end
        return
    end

    cancelJob()
    _job = style.fetch(function(ok, err)
        _job = nil
        if not ok then
            if cb then
                cb(false, err)
            end
            return
        end
        if day ~= nil then
            Settings.setSavedDay(day)
        end
        Settings.applyCover(path)
        if cb then
            cb(true)
        end
    end)
end

--- 切换模式：只写状态，落盘不依赖网络。
--- 选样式后由调用方在联网时机调 M.refresh。
---@param mode string 样式 id 或 "ko"
function M.setMode(mode)
    cancelJob()
    local style = Styles.find(mode)
    if style == nil then
        if M.currentStyle() ~= nil then
            Settings.restorePrev()
        end
        Settings.setMode(nil)
        return
    end

    Settings.backupIfNeeded()
    Settings.setMode(style.id)
    -- 重选即重下：清今日标记
    Settings.setSavedDay(nil)
end

--- 插件启动：有缓存则立刻接管；缺失或过期则下一拍后台下载。
function M.bootstrap()
    local style = M.currentStyle()
    if style == nil then
        return
    end
    -- 新安装默认启用样式，也必须先保存用户原有 KOReader 锁屏配置。
    Settings.backupIfNeeded()
    if fileOk(style.path()) then
        Settings.applyCover(style.path())
    end
    UIManager:nextTick(function()
        M.refreshInBackground()
    end)
end

return M
