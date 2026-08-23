--[[--
翻页动画功能门面：把 KOReader 的 `swipe_animations` 设置与补丁安装/恢复绑定。

补丁管理器本身不暴露 UI，这里只负责「设置开关 → 安装/恢复 → 重启提示」的编排，
供桌面设置页与插件启动检测复用。

@module koplugin.book.patch.page_turn_animation
--]]

local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local Manager = require("patch.manager")
require("l10n").apply()
local _ = require("gettext")
local T = require("ffi/util").template

local PageTurnAnimation = {}

PageTurnAnimation.FEATURE = "page_turn_animation"

local _startup_checked = false

--- fdroid Android 把 userpatch 干成 no-op，补丁写了也不会被加载。
---@return string|nil 不支持原因；支持时返回 nil
local function unsupportedReason()
    local ok, android = pcall(require, "android")
    if ok and type(android) == "table" and android.prop and android.prop.flavor == "fdroid" then
        return "fdroid Android does not load user patches"
    end
    return nil
end

--- 动画是否开启（以 KOReader 全局设置为准）。
---@return boolean
function PageTurnAnimation.isEnabled()
    return G_reader_settings:isTrue("swipe_animations")
end

--- 补丁当前是否完整安装。
---@return boolean
function PageTurnAnimation.isApplied()
    return Manager.isApplied(PageTurnAnimation.FEATURE)
end

local PREV_REFRESH_KEY = "swipe_animations_prev_refresh_rate"

--- 动画开启时把完全刷新率强制为「从不」，避免全刷闪烁打断动画；先备份原值。
---@return nil
local function forceFullRefreshNever()
    if G_reader_settings:has(PREV_REFRESH_KEY) then return end
    G_reader_settings:saveSetting(PREV_REFRESH_KEY, {
        day = G_reader_settings:readSetting("full_refresh_count"),
        night = G_reader_settings:readSetting("night_full_refresh_count"),
    })
    G_reader_settings:saveSetting("full_refresh_count", 0)
    G_reader_settings:saveSetting("night_full_refresh_count", 0)
end

--- 关闭动画时恢复用户原先的完全刷新率。
---@return nil
local function restoreFullRefresh()
    local prev = G_reader_settings:readSetting(PREV_REFRESH_KEY)
    if prev == nil then return end
    if prev.day ~= nil then
        G_reader_settings:saveSetting("full_refresh_count", prev.day)
    else
        G_reader_settings:delSetting("full_refresh_count")
    end
    if prev.night ~= nil then
        G_reader_settings:saveSetting("night_full_refresh_count", prev.night)
    else
        G_reader_settings:delSetting("night_full_refresh_count")
    end
    G_reader_settings:delSetting(PREV_REFRESH_KEY)
end

local _refresh_guard_installed = false

--- 运行时拦截刷新率设置：动画开启期间强制为「从不」（0），避免全刷闪烁打断
--- 动画。纯内存包装，不修改任何 KOReader 文件，重启后失效。
---@return nil
local function installRefreshGuard()
    if _refresh_guard_installed then return end
    _refresh_guard_installed = true
    local orig = UIManager.setRefreshRate
    UIManager.setRefreshRate = function(self, rate, night_rate)
        if PageTurnAnimation.isEnabled() then
            rate, night_rate = 0, 0
        end
        return orig(self, rate, night_rate)
    end
end

--- 开启/关闭动画：先装/卸补丁，成功后再落设置。
---@param on boolean
---@return table { ok = true } | { ok = false, err = string }
function PageTurnAnimation.setEnabled(on)
    local res
    if on then
        local why = unsupportedReason()
        if why then return { ok = false, err = why } end
        res = Manager.install(PageTurnAnimation.FEATURE)
    else
        res = Manager.restore(PageTurnAnimation.FEATURE)
    end
    if not res.ok then
        return res
    end
    if on then
        forceFullRefreshNever()
    else
        restoreFullRefresh()
    end
    G_reader_settings:saveSetting("swipe_animations", on)
    return { ok = true }
end

--- 补丁改动后提示重启（补丁与 uimanager.lua 只在启动时加载）。
---@return nil
function PageTurnAnimation.promptRestart()
    local dialog
    dialog = ConfirmBox:new{
        text = _("翻页动画补丁已更新，需重启 KOReader 生效。"),
        ok_text = _("立即重启"),
        cancel_text = _("稍后"),
        ok_callback = function()
            UIManager:close(dialog)
            UIManager:restartKOReader()
        end,
    }
    UIManager:show(dialog)
end

--- 启动检测：设置开启但补丁失效（如 KOReader 升级覆盖核心文件）时提示重装。
---@return nil
function PageTurnAnimation.checkStartup()
    if _startup_checked then return end
    _startup_checked = true
    installRefreshGuard()
    if unsupportedReason() then return end
    if not PageTurnAnimation.isEnabled() then return end
    if PageTurnAnimation.isApplied() then
        forceFullRefreshNever()
        return
    end

    local dialog
    dialog = ConfirmBox:new{
        text = _("翻页动画补丁已失效（可能因 KOReader 升级）。是否重新安装？"),
        ok_text = _("重新安装"),
        cancel_text = _("取消"),
        ok_callback = function()
            UIManager:close(dialog)
            local res = Manager.install(PageTurnAnimation.FEATURE)
            if res.ok then
                forceFullRefreshNever()
                PageTurnAnimation.promptRestart()
            else
                UIManager:show(InfoMessage:new{
                    text = T(_("重新安装失败：%1"), tostring(res.err or "")),
                    timeout = 3,
                })
            end
        end,
    }
    UIManager:show(dialog)
end

return PageTurnAnimation
