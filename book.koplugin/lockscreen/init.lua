--[[--
锁屏显示入口：可选接管 KOReader screensaver。

  "ko"     — KOReader 默认锁屏（不设屏保图片，显示锁屏信息）
  其余     — 已注册样式（见 styles/base.lua），下载图片后设 document_cover

对外 API：mode / label / options / imagePath / setMode / refresh /
refreshInBackground / onResume / bootstrap。编排（在飞任务取消、按天重下）
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

---@param mode string|nil 样式 id；省略时使用当前样式
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

---@param path string
---@return boolean
local function fileOk(path)
    local attr = lfs.attributes(path)
    return attr ~= nil and attr.mode == "file" and (attr.size or 0) > 0
end

--- 取消当前样式生成任务；无任务时不操作。
local function cancelJob()
    if _job and _job.cancel then
        _job.cancel()
    end
    _job = nil
end

--- 网络已可用时在后台刷新；离线直接返回，等待 NetworkConnected 再试。
--- style.fetch 走 Turbo，不阻塞 UI。
---@return nil
function M.refreshInBackground()
    if M.currentStyle() == nil or _job then
        return
    end
    local style = M.currentStyle()
    if not style.local_render then
        local NetworkMgr = require("ui/network/manager")
        if not NetworkMgr:isOnline() then
            return
        end
    end
    M.refresh()
end

--- 下载样式图片并接管锁屏；今日已下且文件还在则直接复用。
--- 失败不改模式，等下次 onResume / NetworkConnected 重试。
---@param cb fun(ok: boolean, err: any)|nil 完成回调
---@param force boolean|nil 忽略样式缓存；仅用于为下一次锁屏预生成新内容
function M.refresh(cb, force)
    -- 等联网（wifi 弹窗）期间用户可能已切回跟随
    local style = M.currentStyle()
    if style == nil then
        return
    end

    local path = style.path()
    local day = style.dayKey and style.dayKey() or nil
    if not force and day ~= nil and Settings.savedDay() == day and fileOk(path) then
        Settings.applyCover(path)
        if cb then
            cb(true)
        end
        return
    end

    cancelJob()
    _job = style.fetch(function(ok, err)
        _job = nil
        if M.currentStyle() ~= style then
            return
        end
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

--- 唤醒后为下一次锁屏准备新一言。KOReader 在 Suspend 事件前已经绘制锁屏，
--- 因此刷新必须发生在上一个锁屏周期结束时。
---@return boolean 是否为一言模式并已发起强制刷新
function M.prepareNextLock()
    local style = M.currentStyle()
    if not style or style.id ~= "quote" or M.quoteMode() ~= "hitokoto" then
        return false
    end
    M.refresh(nil, true)
    return true
end

--- 唤醒后准备下一次锁屏内容。
---@return nil
function M.onResume()
    if not M.prepareNextLock() then
        M.refreshInBackground()
    end
end

---@return string today/7d/30d/month
function M.billPeriod()
    return require("utils.settings").get().lock_screen_bill_period or "7d"
end

---@param period string today/7d/30d/month
---@return nil
function M.setBillPeriod(period)
    local allowed = { today = true, ["7d"] = true, ["30d"] = true, month = true }
    if not allowed[period] then
        return
    end
    cancelJob()
    local SettingsStore = require("utils.settings")
    SettingsStore.get().lock_screen_bill_period = period
    SettingsStore.save()
    Settings.setSavedDay(nil)
    Settings.clearCover()
end

---@return string 自定义背景提示文案
function M.backgroundHint()
    local w, h = require("lockscreen.render").size()
    return string.format(".moon/screensaver/custom.png · %d × %d", w, h)
end

---@return string custom/bing/none
function M.backgroundMode()
    return require("utils.settings").get().lock_screen_background or "bing"
end

---@param mode string custom/bing/cover/none
---@return nil
function M.setBackgroundMode(mode)
    if mode ~= "custom" and mode ~= "bing" and mode ~= "cover" and mode ~= "none" then
        return
    end
    cancelJob()
    local SettingsStore = require("utils.settings")
    SettingsStore.get().lock_screen_background = mode
    SettingsStore.save()
    Settings.setSavedDay(nil)
    Settings.clearCover()
end

---@return string simple/bookmark/cover
function M.readingMode()
    return require("utils.settings").get().lock_screen_reading_mode or "bookmark"
end

---@param mode string simple/bookmark/cover
---@return nil
function M.setReadingMode(mode)
    local allowed = { simple = true, bookmark = true, cover = true }
    if not allowed[mode] then
        return
    end
    cancelJob()
    local SettingsStore = require("utils.settings")
    SettingsStore.get().lock_screen_reading_mode = mode
    SettingsStore.save()
    Settings.setSavedDay(nil)
    Settings.clearCover()
end

---@return string highlight/hitokoto
function M.quoteMode()
    return require("utils.settings").get().lock_screen_quote_mode or "highlight"
end

---@param mode string highlight/hitokoto
---@return nil
function M.setQuoteMode(mode)
    if mode ~= "highlight" and mode ~= "hitokoto" and mode ~= "none" then
        return
    end
    cancelJob()
    local SettingsStore = require("utils.settings")
    SettingsStore.get().lock_screen_quote_mode = mode
    SettingsStore.save()
    Settings.setSavedDay(nil)
    Settings.clearCover()
end

---@return string
function M.quotePosition()
    return require("utils.settings").get().lock_screen_quote_position or "center-center"
end

---@param position string
---@return nil
function M.setQuotePosition(position)
    local allowed = {
        ["top-left"] = true, ["top-center"] = true, ["top-right"] = true,
        ["center-left"] = true, ["center-center"] = true, ["center-right"] = true,
        ["bottom-left"] = true, ["bottom-center"] = true, ["bottom-right"] = true,
    }
    if not allowed[position] then return end
    cancelJob()
    local settings = require("utils.settings")
    settings.get().lock_screen_quote_position = position
    settings.save()
    Settings.setSavedDay(nil)
    Settings.clearCover()
end

---@return boolean
function M.quoteWide()
    return require("utils.settings").get().lock_screen_quote_wide ~= false
end

---@param wide boolean
---@return nil
function M.setQuoteWide(wide)
    cancelJob()
    local settings = require("utils.settings")
    settings.get().lock_screen_quote_wide = wide == true
    settings.save()
    Settings.setSavedDay(nil)
    Settings.clearCover()
end

--- 高亮改变时只使高亮样式失效，避免其它样式无意义重绘。
---@return nil
function M.onAnnotationsModified()
    local style = M.currentStyle()
    if not style or style.id ~= "quote" or M.quoteMode() ~= "highlight" then
        return
    end
    Settings.setSavedDay(nil)
    M.refreshInBackground()
end

--- 切换模式：只写状态，落盘不依赖网络。
--- 选样式后由调用方在联网时机调 M.refresh。
---@param mode string 样式 id 或 "ko"
---@return nil
function M.setMode(mode)
    cancelJob()
    local style = Styles.find(mode)
    if style == nil then
        Settings.setMode(nil)
        Settings.clearCover()
        return
    end

    Settings.setMode(style.id)
    -- 重选即重下：清今日标记
    Settings.setSavedDay(nil)
    Settings.applyCover(style.path())
end

---@param mode string 样式 id
---@return boolean
function M.canRefreshOffline(mode)
    local style = Styles.find(mode)
    return style ~= nil and style.local_render == true
end

--- 插件启动：有缓存则立刻接管；缺失或过期则下一拍后台下载。
---@return nil
function M.bootstrap()
    local style = M.currentStyle()
    if style == nil then
        return
    end
    Settings.applyCover(style.path())
    UIManager:nextTick(function()
        M.refreshInBackground()
    end)
end

return M
