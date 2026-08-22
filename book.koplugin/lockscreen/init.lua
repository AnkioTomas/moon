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
local ScreenSaver = require("lockscreen.settings")
local MoonSettings = require("utils.settings")
local _ = require("gettext")

local M = {}

local _job

--- 取消上一轮背景下载或文案请求，避免旧回调覆盖新设置。
---@return nil
local function cancelJob()
    if _job and _job.cancel then
        _job.cancel()
    end
    _job = nil
end

--- 设置发生变化时同时失效组合图和系统 document_cover。
---@return nil
local function invalidate()
    cancelJob()
    MoonSettings.get().lock_screen_day = nil
    ScreenSaver.clearCover()
end

--- 统一处理设置写入：先撤下旧图，再保存新值。
---@param key string
---@param value any
---@return nil
local function saveSetting(key, value)
    invalidate()
    MoonSettings.get()[key] = value
    MoonSettings.save()
end

--- 是否启用了插件组合锁屏。
---@return boolean
function M.isCompose()
    return MoonSettings.get().lock_screen == "compose"
end

--- 在后台按需刷新组合图，不阻塞桌面或阅读界面。
--- force 用于阅读状态或注解发生变化时立即重建。
---@param force boolean|nil
---@return nil
function M.refreshInBackground(force)
    if not M.isCompose() then
        return
    end
    if _job then
        if not force then return end
        cancelJob()
    end
    if not M.canRefreshOffline() then
        local NetworkMgr = require("ui/network/manager")
        if not NetworkMgr:isOnline() then
            return
        end
    end
    M.refresh(nil, force)
end

--- 生成并安装当前锁屏图片。
---@param cb fun(ok: boolean, err: any)|nil
---@param force boolean|nil
function M.refresh(cb, force)
    if not M.isCompose() then
        return
    end
    local output_path = Compose.outputPath()
    if Compose.cacheValid(force) then
        ScreenSaver.applyCover(output_path)
        if cb then cb(true) end
        return
    end
    cancelJob()

    _job = Compose.build(function(ok, err, ready_path)
        _job = nil
        if not M.isCompose() then
            return
        end
        if not ok then
            if cb then cb(false, err) end
            return
        end
        -- 资源可能在生成期间选定文件夹壁纸，完成后再取最终路径和缓存键。
        output_path = ready_path or Compose.outputPath()
        MoonSettings.get().lock_screen_day = Compose.dayKey()
        MoonSettings.save()
        ScreenSaver.applyCover(output_path)
        if cb then cb(true) end
    end)
end

--- 响应宿主恢复事件，刷新动态主体或每日背景。
---@return nil
function M.onResume()
    local component = Components.find(M.component())
    if component and component.refresh_on_resume then
        M.refreshInBackground(true)
        return
    end
    M.refreshInBackground(
        component and component.live == true
            or Compose.asset().refresh_on_resume == true
    )
end

--- 返回账单主体使用的统计周期。
---@return string
function M.billPeriod()
    return MoonSettings.get().lock_screen_bill_period or "7d"
end

--- 设置账单统计周期并使组合图失效。
---@param period string
---@return nil
function M.setBillPeriod(period)
    local allowed = { today = true, ["7d"] = true, ["30d"] = true, month = true }
    if not allowed[period] then return end
    saveSetting("lock_screen_bill_period", period)
end

--- 返回自定义背景文件的帮助文案。
---@return string
function M.backgroundHint()
    local w, h = Layout.portraitSize()
    return string.format(".moon/screensaver/custom.png · %d × %d", w, h)
end

--- 返回文件夹背景的扫描目录帮助文案。
---@return string
function M.folderHint()
    return ".moon/screensaver/wallpapers/"
end

--- 返回当前生效的背景 ID。
---@return string
function M.backgroundMode()
    return Compose.backgroundMode()
end

--- 写入背景 ID，并清除旧组合图。
---@param mode string
---@return nil
function M.setBackgroundMode(mode)
    if not Background.validMode(mode) then return end
    saveSetting("lock_screen_background", mode)
end

--- 构造背景设置页选项。
---@return {text: string, value: string}[]
function M.backgroundOptions()
    return {
        { text = _("自定义"), value = "custom" },
        { text = _("必应壁纸"), value = "bing" },
        { text = _("当前阅读书籍封面"), value = "cover" },
        { text = _("文件夹壁纸"), value = "folder" },
        { text = _("无"), value = "none" },
    }
end

--- 返回当前生效的主体 ID。
---@return string
function M.component()
    return Compose.componentId()
end

--- 切换主体并按主体能力修正宽窄布局。
---@param id string
---@return nil
function M.setComponent(id)
    local component = Components.find(id)
    if not component then return end
    invalidate()
    local c = MoonSettings.get()
    c.lock_screen_component = id
    if component.supports_narrow == false then
        c.lock_screen_wide = true
    end
    MoonSettings.save()
end

--- 构造主体设置页选项。
---@return {text: string, value: string}[]
function M.componentOptions()
    return Components.options()
end

--- 返回自定义留言；空值时使用默认古诗句。
---@return string
function M.customMessage()
    return MoonSettings.get().lock_screen_custom_message
        or "读书不觉已春深，一寸光阴一寸金。"
end

--- 保存去除首尾空白后的自定义留言。
---@param text string
---@return nil
function M.setCustomMessage(text)
    if type(text) ~= "string" then return end
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return end
    saveSetting("lock_screen_custom_message", text)
end

--- 返回主体位置。
---@return string
function M.position()
    return Compose.position()
end

--- 保存合法的九宫格位置。
---@param position string
---@return nil
function M.setPosition(position)
    local component = Components.find(M.component())
    if component and component.supports_position == false then return end
    if not Layout.validPosition(position) then return end
    saveSetting("lock_screen_position", position)
end

--- 返回当前主体是否使用宽屏面板。
---@return boolean
function M.wide()
    return Compose.wide()
end

--- 保存宽窄布局；不支持窄屏的主体强制保持宽屏。
---@param wide boolean
---@return nil
function M.setWide(wide)
    local component = Components.find(M.component())
    if component and component.supports_narrow == false then
        wide = true
    end
    saveSetting("lock_screen_wide", wide == true)
end

--- 当前主体是否提供窄屏变体。
---@return boolean
function M.supportsNarrow()
    local component = Components.find(M.component())
    return component ~= nil and component.supports_narrow == true
end

--- 注解变化后刷新依赖高亮数据的主体。
---@return nil
function M.onAnnotationsModified()
    if not M.isCompose() then
        return
    end
    local component = Components.find(M.component())
    if not component or not component.refresh_on_annotations then return end
    MoonSettings.get().lock_screen_day = nil
    MoonSettings.save()
    M.refreshInBackground(true)
end

--- 切换是否接管系统锁屏；启用时先进入准备态，再异步生成新图。
---@param mode string
---@return nil
function M.setMode(mode)
    cancelJob()
    if mode ~= "compose" then
        MoonSettings.get().lock_screen = "ko"
        MoonSettings.save()
        ScreenSaver.clearCover()
        return
    end
    local c = MoonSettings.get()
    c.lock_screen = "compose"
    if not Components.find(c.lock_screen_component) then
        c.lock_screen_component = "current"
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
    c.lock_screen_day = nil
    MoonSettings.save()
    -- 新图尚未生成：只撤旧封面。残留 compose.png 不能 apply，否则会立刻盖回旧图。
    -- refresh 成功后再 applyCover。
    ScreenSaver.clearCover()
end

--- 判断当前组合锁屏能否在无网络时刷新。
---@return boolean
function M.canRefreshOffline()
    if not M.isCompose() then return true end
    local asset = Compose.asset()
    local component = Components.find(M.component())
    if asset.network == true then
        return false
    end
    if component and component.needs_network then
        return false
    end
    return true
end

--- 插件启动时安装已有组合图，并安排一次后台校验。
---@return nil
function M.bootstrap()
    if not M.isCompose() then
        return
    end
    -- 只有缓存键和文件都有效时才安装旧封面；direct 资源失败时不能把
    -- 残留 compose.png 当成当前主体显示。
    if Compose.cacheValid() then
        ScreenSaver.applyCover(Compose.outputPath())
    else
        ScreenSaver.clearCover()
    end
    UIManager:nextTick(function()
        M.refreshInBackground(true)
    end)
end

return M
