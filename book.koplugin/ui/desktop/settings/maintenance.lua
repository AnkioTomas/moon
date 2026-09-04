--[[-- 维护与关于设置项。
@module koplugin.book.ui.desktop.settings.maintenance
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local TextWidget = require("ui/widget/textwidget")
local UI = require("ui.components.bookui")
local Icon = require("ui.components.icon")
local SettingRow = require("ui.components.settingrow")
local Cache = require("book.cache")
local MoonSettings = require("utils.settings")
local _ = require("gettext")
local T = require("ffi/util").template

local Maintenance = {}
local REPO_URL = "https://github.com/AnkioTomas/moon"
local REPO_HOST = "github.com/AnkioTomas/moon"

--- 读取插件版本号。
--- bookversion 由 CI 打 tag 时注入，源码树里可能没有，此时退化为 dev 版本号。
---@return string
local function pluginVersion()
    local ok, ver = pcall(require, "bookversion")
    if ok and type(ver) == "string" and ver ~= "" then return ver end
    return "0.0.0-dev"
end

--- 弹出「关于」对话框：图标、名称、版本、简介、作者与许可证。
--- 仅设备支持外部链接时才给「打开 GitHub」按钮。
local function showAbout()
    local ver, dialog = pluginVersion()
    local buttons = {}
    if Device:canOpenLink() then
        buttons[#buttons + 1] = {{ text = _("打开 GitHub"), callback = function() Device:openLink(REPO_URL) end }}
    end
    buttons[#buttons + 1] = {{ text = _("关闭"), callback = function() UIManager:close(dialog) end }}
    dialog = ButtonDialog:new{ title = _("关于"), title_align = "center", use_info_style = false, buttons = buttons }
    local body = VerticalGroup:new{ align = "center" }
    local icon = Icon.widget{ name = "info", size = 44 }
    if icon then table.insert(body, icon); table.insert(body, VerticalSpan:new{ width = UI.sz(10) }) end
    table.insert(body, TextWidget:new{ text = _("月读"), face = UI.face("cfont", 20) })
    table.insert(body, VerticalSpan:new{ width = UI.sz(4) })
    table.insert(body, TextWidget:new{ text = T(_("版本 %1"), ver), face = UI.face("xx_smallinfofont", 13), fgcolor = UI.muted() })
    table.insert(body, VerticalSpan:new{ width = UI.sz(12) })
    table.insert(body, TextBoxWidget:new{
        text = _("面向 KOReader 的书库桌面，支持多数据源与阅读进度同步。"),
        face = UI.face("xx_smallinfofont", 13), width = dialog:getAddedWidgetAvailableWidth(),
        alignment = "center", fgcolor = UI.dim(),
    })
    table.insert(body, VerticalSpan:new{ width = UI.sz(14) })
    table.insert(body, TextWidget:new{ text = "AnkioTomas", face = UI.face("cfont", 14) })
    table.insert(body, VerticalSpan:new{ width = UI.sz(2) })
    table.insert(body, TextWidget:new{ text = REPO_HOST, face = UI.face("xx_smallinfofont", 12), fgcolor = UI.muted() })
    table.insert(body, VerticalSpan:new{ width = UI.sz(4) })
    table.insert(body, TextWidget:new{ text = _("GNU GPLv3"), face = UI.face("xx_smallinfofont", 11), fgcolor = UI.muted() })
    dialog:addWidget(body)
    UIManager:show(dialog)
end

--- 造「清理缓存」设置行的构造器。
--- 缓存体积异步测量，结果缓存在 desktop 上，首次显示「计算中…」并在算完后重建设置页；
--- 清理会连带作废首页与书库状态，因为封面等资源就在 cache 里。
---@param desktop table 桌面实例
---@return fun(iw: number): table
function Maintenance.cacheRow(desktop)
    return function(iw)
        local cache_size = desktop._cache_size_label or _("计算中…")
        if desktop._cache_size_label == nil and not desktop._cache_size_job then
            desktop._cache_size_job = Cache.sizeBytesAsync(function(bytes)
                desktop._cache_size_job = nil
                if desktop._closed then return end
                local label = bytes > 0
                    and (require("util").getFriendlySize(bytes) or tostring(bytes)) or "0"
                desktop._cache_size_label = label
                if desktop.tab == "settings" then desktop:rebuild() end
            end)
        end
        return SettingRow.build(iw, {
            kind = "action", icon = "delete", title = _("清理缓存"), status = cache_size, status_on = true,
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = T(_("删除 .moon/cache（%1）？"), cache_size), ok_text = _("清理"),
                    ok_callback = function()
                        if desktop._cache_clear_job then return end
                        UIManager:show(InfoMessage:new{ text = _("正在清理缓存…"), timeout = 1 })
                        desktop._cache_clear_job = Cache.clearAsync(function(ok)
                            desktop._cache_clear_job = nil
                            if desktop._closed then return end
                            if ok then
                                desktop._cache_size_label = "0"
                                require("ui.desktop.home").invalidate(desktop)
                                desktop._library_state = nil
                                desktop:rebuild()
                            end
                            UIManager:show(InfoMessage:new{ text = ok and _("已清理") or _("清理失败"), timeout = 2 })
                        end)
                    end,
                })
            end,
        })
    end
end

--- 造「调试日志」开关；控制 DEBUG/INFO，WARN/ERROR 始终写入独立日志。
---@param desktop table 桌面实例
---@return fun(iw: number): table
function Maintenance.debugLogRow(desktop)
    return function(iw)
        local enabled = MoonSettings.get("common").book_debug_enabled
        return SettingRow.build(iw, {
            kind = "toggle", icon = "bug_report", title = _("调试日志"),
            status = enabled and _("开") or _("关"), status_on = enabled,
            callback = function()
                MoonSettings.save({ book_debug_enabled = not enabled })
                desktop:rebuild()
            end,
        })
    end
end

--- 造「关于」设置行的构造器，状态位显示当前版本号。
---@return fun(iw: number): table
function Maintenance.aboutRow()
    return function(iw)
        return SettingRow.build(iw, { kind = "nav", icon = "info", title = _("关于"), status = pluginVersion(), status_on = true, callback = showAbout })
    end
end

--- 造「关闭桌面」设置行的构造器。
---@param desktop table 桌面实例
---@return fun(iw: number): table
function Maintenance.closeRow(desktop)
    return function(iw)
        return SettingRow.build(iw, { kind = "action", icon = "close", title = _("关闭桌面"), callback = function() desktop:onClose() end })
    end
end

return Maintenance
