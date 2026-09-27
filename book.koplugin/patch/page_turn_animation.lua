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

--- 动画风格设置键；运行时补丁每次翻页读取，切换无需重启。
PageTurnAnimation.STYLE_KEY = "swipe_animation_style"

--- 可选风格；value 必须与 2-swipe-animation-core.lua 的 SwipeAnimation.STYLES 键一致。
PageTurnAnimation.STYLES = {
    { text = _("擦除"), value = "wipe" },
    { text = _("翻页阴影"), value = "shadow" },
    { text = _("纵向擦除"), value = "wipe_vertical" },
    { text = _("斜向擦除"), value = "diagonal" },
    { text = _("分割"), value = "split" },
    { text = _("百叶窗"), value = "blinds" },
    { text = _("梳状"), value = "comb" },
    { text = _("随机线条"), value = "random_bars" },
    { text = _("方框"), value = "box" },
    { text = _("螺旋"), value = "spiral" },
    { text = _("时钟"), value = "clock" },
    { text = _("逐行"), value = "typewriter" },
    { text = _("棋盘"), value = "checkerboard" },
    { text = _("随机方块"), value = "random_blocks" },
}

--- 当前风格；未设置或已下线的值与运行时补丁一致，回退为第一项（擦除）。
---@return { text: string, value: string }
function PageTurnAnimation.currentStyle()
    local value = G_reader_settings:readSetting(PageTurnAnimation.STYLE_KEY)
    for _, item in ipairs(PageTurnAnimation.STYLES) do
        if item.value == value then return item end
    end
    return PageTurnAnimation.STYLES[1]
end

--- 弹出风格单选，选中后落设置；下一次翻页即生效。
---@param on_change fun()|nil 风格真正改变后回调（刷新调用方界面）
function PageTurnAnimation.pickStyle(on_change)
    local current = PageTurnAnimation.currentStyle().value
    require("ui.views.popup").list{
        title = _("翻页动画风格"), items = PageTurnAnimation.STYLES,
        current = current, choice_icons = true, centered = true,
        on_select = function(value)
            if not value or value == current then return end
            G_reader_settings:saveSetting(PageTurnAnimation.STYLE_KEY, value)
            if on_change then on_change() end
        end,
    }
end

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

local PREV_REFRESH_KEY = "swipe_animations_prev_refresh_rate"

--- 动画首次开启时把完全刷新率改成「从不」，避免全刷闪烁打断动画。
--- 只改一次并备份原值；用户之后可以自行改回，Moon 不再反复覆盖。
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
local function restoreFullRefresh()
    local prev = G_reader_settings:readSetting(PREV_REFRESH_KEY)
    if prev == nil then return end
    -- 只恢复仍保持旧版本强制值 0 的一侧；用户后来手动修改过就不能覆盖。
    for side, key in pairs({ day = "full_refresh_count", night = "night_full_refresh_count" }) do
        if G_reader_settings:readSetting(key) == 0 then
            if prev[side] ~= nil then
                G_reader_settings:saveSetting(key, prev[side])
            else
                G_reader_settings:delSetting(key)
            end
        end
    end
    G_reader_settings:delSetting(PREV_REFRESH_KEY)
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
function PageTurnAnimation.checkStartup()
    if _startup_checked then return end
    _startup_checked = true
    if unsupportedReason() then return end
    if not PageTurnAnimation.isEnabled() then return end
    if Manager.isApplied(PageTurnAnimation.FEATURE) then
        forceFullRefreshNever()
        -- 插件升级后运行时补丁内容可能已变，isApplied 只看文件在不在；重装是幂等的。
        local res = Manager.install(PageTurnAnimation.FEATURE)
        if not res.ok then
            UIManager:show(InfoMessage:new{
                text = T(_("翻页动画补丁更新失败：%1"), tostring(res.err or "")),
                timeout = 3,
            })
        elseif res.changed then
            PageTurnAnimation.promptRestart()
        end
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
