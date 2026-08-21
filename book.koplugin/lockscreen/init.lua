--[[--
锁屏显示入口：可选接管 KOReader screensaver。

  "ko"      — KOReader 默认锁屏
  "compose" — 组合壁纸（背景 × 主体 × 九宫格 × 宽窄）

@module koplugin.book.lockscreen
--]]

local UIManager = require("ui/uimanager")
local Compose = require("lockscreen.compose")
local Components = require("lockscreen.components.base")
local Background = require("lockscreen.background")
local Layout = require("lockscreen.layout")
local Settings = require("lockscreen.settings")
local _ = require("gettext")

local M = {}

local _job

local function cancelJob()
    if _job and _job.cancel then
        _job.cancel()
    end
    _job = nil
end

local function invalidate()
    cancelJob()
    Settings.setSavedDay(nil)
    Settings.clearCover()
end

---@return boolean
function M.isCompose()
    return Settings.mode() == "compose"
end

---@return string ko|compose
function M.mode()
    return M.isCompose() and "compose" or "ko"
end

---@param mode string|nil
---@return string
function M.label(mode)
    mode = mode or M.mode()
    if mode == "compose" then
        return _("组合壁纸")
    end
    return _("跟随 KOReader")
end

---@return {text: string, value: string}[]
function M.options()
    return {
        { text = _("跟随 KOReader"), value = "ko" },
        { text = _("组合壁纸"), value = "compose" },
    }
end

---@return string|nil
function M.imagePath()
    return M.isCompose() and Compose.path() or nil
end

---@return nil
function M.refreshInBackground()
    if not M.isCompose() or _job then
        return
    end
    if not M.canRefreshOffline("compose") then
        local NetworkMgr = require("ui/network/manager")
        if not NetworkMgr:isOnline() then
            return
        end
    end
    M.refresh()
end

---@param cb fun(ok: boolean, err: any)|nil
---@param force boolean|nil
function M.refresh(cb, force)
    if not M.isCompose() then
        return
    end
    local path = Compose.path()
    local day = Compose.dayKey()
    if Compose.cacheValid(force) then
        Settings.applyCover(path)
        if cb then cb(true) end
        return
    end
    cancelJob()
    _job = Compose.build(function(ok, err)
        _job = nil
        if not M.isCompose() then
            return
        end
        if not ok then
            if cb then cb(false, err) end
            return
        end
        Settings.setSavedDay(day)
        Settings.applyCover(path)
        if cb then cb(true) end
    end)
end

---@return boolean
function M.prepareNextLock()
    if not M.isCompose() or M.component() ~= "hitokoto" then
        return false
    end
    M.refresh(nil, true)
    return true
end

---@return nil
function M.onResume()
    if not M.prepareNextLock() then
        M.refreshInBackground()
    end
end

---@return string
function M.billPeriod()
    return require("utils.settings").get().lock_screen_bill_period or "7d"
end

---@param period string
---@return nil
function M.setBillPeriod(period)
    local allowed = { today = true, ["7d"] = true, ["30d"] = true, month = true }
    if not allowed[period] then return end
    invalidate()
    local store = require("utils.settings")
    store.get().lock_screen_bill_period = period
    store.save()
end

---@return string
function M.backgroundHint()
    local w, h = require("lockscreen.render").size()
    return string.format(".moon/screensaver/custom.png · %d × %d", w, h)
end

---@return string
function M.backgroundMode()
    return Compose.backgroundMode()
end

---@param mode string
---@return nil
function M.setBackgroundMode(mode)
    if not Background.validMode(mode) then return end
    invalidate()
    local store = require("utils.settings")
    store.get().lock_screen_background = mode
    store.save()
end

---@return {text: string, value: string}[]
function M.backgroundOptions()
    return {
        { text = _("自定义"), value = "custom" },
        { text = _("摸鱼日报"), value = "myrl" },
        { text = _("书架"), value = "bookshelf" },
        { text = _("必应壁纸"), value = "bing" },
        { text = _("当前阅读书籍封面"), value = "cover" },
        { text = _("无"), value = "none" },
    }
end

---@return string
function M.component()
    return Compose.componentId()
end

---@param id string
---@return nil
function M.setComponent(id)
    if not Components.find(id) then return end
    invalidate()
    local store = require("utils.settings")
    local c = store.get()
    c.lock_screen_component = id
    local component = Components.find(id)
    if component and not component.supports_narrow then
        c.lock_screen_wide = true
    end
    store.save()
end

---@return {text: string, value: string}[]
function M.componentOptions()
    return Components.options()
end

---@return string
function M.position()
    return Compose.position()
end

---@param position string
---@return nil
function M.setPosition(position)
    if not Layout.validPosition(position) then return end
    invalidate()
    local store = require("utils.settings")
    store.get().lock_screen_position = position
    store.save()
end

---@return boolean
function M.wide()
    return Compose.wide()
end

---@param wide boolean
---@return nil
function M.setWide(wide)
    local component = Components.find(M.component())
    if component and not component.supports_narrow then
        wide = true
    end
    invalidate()
    local store = require("utils.settings")
    store.get().lock_screen_wide = wide == true
    store.save()
end

---@return boolean
function M.supportsNarrow()
    local component = Components.find(M.component())
    return component ~= nil and component.supports_narrow == true
end

---@return nil
function M.onAnnotationsModified()
    if not M.isCompose() or M.component() ~= "highlight" then
        return
    end
    Settings.setSavedDay(nil)
    M.refreshInBackground()
end

---@param mode string
---@return nil
function M.setMode(mode)
    cancelJob()
    if mode ~= "compose" then
        Settings.setMode("ko")
        Settings.clearCover()
        return
    end
    local store = require("utils.settings")
    local c = store.get()
    c.lock_screen = "compose"
    if not Components.find(c.lock_screen_component) then
        c.lock_screen_component = "bookmark"
    end
    if not Background.validMode(c.lock_screen_background) then
        c.lock_screen_background = "bing"
    end
    if not Layout.validPosition(c.lock_screen_position) then
        c.lock_screen_position = "center-center"
    end
    if c.lock_screen_wide == nil then
        c.lock_screen_wide = true
    end
    store.save()
    Settings.setSavedDay(nil)
    -- 新图尚未生成时先撤下旧封面，显示准备态；refresh 成功后再 applyCover。
    Settings.clearCover()
    Settings.applyCover(Compose.path())
end

---@param mode string|nil
---@return boolean
function M.canRefreshOffline(mode)
    if mode == "ko" or (mode == nil and not M.isCompose()) then
        return true
    end
    local bg = M.backgroundMode()
    local component = Components.find(M.component())
    if bg == "myrl" or bg == "bing" then
        return false
    end
    if component and component.needs_network then
        return false
    end
    return true
end

---@return nil
function M.bootstrap()
    if not M.isCompose() then
        return
    end
    Settings.applyCover(Compose.path())
    UIManager:nextTick(function()
        M.refreshInBackground()
    end)
end

return M
