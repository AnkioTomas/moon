--[[-- 设备设置项。

「我的设备」第一组是名称与头像（锁屏密码界面等处显示），后面是本机信息。
setting.device_section 在固件后面加一行，点进去是单独的子页。
版本行点按走 setting.version_check（没人登记就只显示版本）。
作者、许可证和 GitHub 在「关于」弹窗里。

@module koplugin.book.desktop.pages.setting.device
--]]

require("l10n").apply()

local DeviceInfo = require("utils.device")
local Image = require("utils.image")
local Input = require("ui.themes.widgets.input")
local QR = require("ui.themes.widgets.qr")
local Row = require("ui.themes.widgets.row")
local Settings = require("utils.settings")
local Text = require("utils.text")
local _ = require("gettext")

local REPO_URL = "https://github.com/AnkioTomas/moon"
local QQ_GROUP_URL = "https://qm.qq.com/q/Q9FHByplqC"
---@class BookSettingsDevice
local Device = {}

--- Bug 反馈群；电池页等 feature 也用同一个群。
Device.BUG_GROUP_URL = "https://qm.qq.com/q/btmL9F4Cl2"

---@param desktop table
---@param key string utils 配置键
---@param value string
local function save(desktop, key, value)
    Settings.get("utils")[key] = value
    Settings.save("utils")
    desktop:updateView()
end

--- 能开链接就开，否则出二维码。墨水屏开不了外部链接。
---@param title string
---@param url string
local function openExternal(title, url)
    local Hardware = require("device")
    if Hardware:canOpenLink() then
        Hardware:openLink(url)
    else
        QR:new{ title = title, text = url, caption = url }:show()
    end
end

---@param icon string
---@param title string
---@param status string
---@return fun(iw: number): table
local function fact(icon, title, status)
    return function(iw)
        return Row.widget({ width = iw, chevron = false, icon = icon, title = title, status = status })
    end
end

---@param screen table
---@return string
local function screenText(screen)
    local w, h = screen:getWidth(), screen:getHeight()
    local dpi = screen:getDPI()
    if dpi and dpi > 0 then return string.format("%d×%d · %d dpi", w, h, dpi) end
    return string.format("%d×%d", w, h)
end

--- 关于弹窗：简介、作者、许可证、GitHub。每行文案都带图标。
local function showAbout()
    require("ui.themes.widgets.sheet"):new{
        title = _("关于"),
        items = {
            { widget = function(width)
                local Theme = require("ui.themes")
                local TextW = require("ui.themes.widgets.text")
                local Icon = require("ui.themes.widgets.icon")
                local HorizontalGroup = require("ui/widget/horizontalgroup")
                local HorizontalSpan = require("ui/widget/horizontalspan")
                local t = Theme.current()
                local gap = Theme.px(t.space.sm)
                local icon = Icon.widget{ name = "info", size = t.control.icon }
                return HorizontalGroup:new{
                    align = "center",
                    icon,
                    HorizontalSpan:new{ width = gap },
                    TextW.box("caption", _("面向 KOReader 的书库桌面，支持多数据源与阅读进度同步。"),
                        math.max(1, width - icon:getSize().w - gap),
                        { color = t.color.muted, bg = t.dialog.bg }),
                }
            end },
            { icon = "person", text = _("作者") .. "  AnkioTomas" },
            { icon = "gavel", text = _("许可证") .. "  GNU GPLv3" },
            { icon = "link", text = _("打开 GitHub"), callback = function()
                openExternal(_("打开 GitHub"), REPO_URL)
            end },
            { icon = "close", text = _("关闭") },
        },
    }:show()
end

--- 我的设备：名称与头像、本机事实（每行有图标）、版本（点按检查更新）、两个群、关于弹窗。
---@param desktop table
---@return BookThemeSection[]
function Device.infoSections(desktop)
    local Hardware = require("device")
    local rows = {}
    if Hardware.model and Hardware.model ~= "" then
        rows[#rows + 1] = fact("devices", _("型号"), Hardware.model)
    end
    rows[#rows + 1] = fact("display_settings", _("屏幕"), screenText(Hardware.screen))
    local fw = Hardware.firmware_rev
    if type(fw) == "string" and fw ~= "" and fw ~= "none" then
        rows[#rows + 1] = fact("memory", _("固件"), fw)
    end
    local pages = require("utils.extension").list("setting.device_section")
    table.sort(pages, function(a, b) return (a.order or 0) < (b.order or 0) end)
    for _idx, item in ipairs(pages) do
        local text = item.status and item.status(desktop) or nil
        rows[#rows + 1] = function(iw)
            return Row.widget({
                width = iw, kind = "nav", icon = item.icon, title = item.title,
                status = text, status_on = text ~= nil,
                callback = function()
                    local on_right = item.right_callback
                    require("desktop.pages.setting.overlay").push(desktop, {
                        id = item.id,
                        title = item.title,
                        docs = item.docs,
                        refresh_seconds = item.refresh_seconds,
                        right_icon = item.right_icon,
                        right_callback = on_right and function() on_right(desktop) end or nil,
                        sections = function() return item.sections(desktop) end,
                    })
                end,
            })
        end
    end
    local rev = require("version"):getCurrentRevision()
    if rev then rows[#rows + 1] = fact("menu_book", "KOReader", rev) end

    local root = desktop.plugin.path
    local check = require("utils.extension").last("setting.version_check")
    local moon = {
        function(iw)
            return Row.widget({
                width = iw, icon = "system_update", title = _("版本"),
                subtitle = check and _("点按检查，长按重装") or nil,
                status = require("bookversion"), status_on = true,
                chevron = check ~= nil,
                callback = check and function() check(root) end or nil,
                hold_callback = check and function() check(root, true) end or nil,
            })
        end,
        function(iw)
            return Row.widget({
                width = iw, kind = "nav", icon = "qr_code", title = _("书友交流群"),
                callback = function() openExternal(_("书友交流群"), QQ_GROUP_URL) end,
            })
        end,
        function(iw)
            return Row.widget({
                width = iw, kind = "nav", icon = "bug_report", title = _("Bug 反馈群"),
                callback = function() openExternal(_("Bug 反馈群"), Device.BUG_GROUP_URL) end,
            })
        end,
        function(iw)
            return Row.widget({
                width = iw, kind = "nav", icon = "menu_book", title = _("使用指南"),
                subtitle = _("官网用户手册"),
                callback = function() require("utils.docs").open("/manual", _("使用指南")) end,
            })
        end,
        function(iw)
            return Row.widget({
                width = iw, kind = "nav", icon = "info", title = _("关于"),
                callback = showAbout,
            })
        end,
    }
    return {
        { title = _("设备名称与头像"), rows = Device:rows(desktop) },
        { title = _("本机"), rows = rows },
        { title = _("月读"), rows = moon },
    }
end

---@param desktop table
---@return (fun(iw: number): table)[]
function Device:rows(desktop)
    return {
        function(iw)
            return Row.widget({
                width = iw, kind = "nav", icon = "badge", title = _("设备名称"),
                subtitle = _("留空使用「月读 - 设备型号」"),
                status = DeviceInfo.name(), status_on = true,
                callback = function()
                    Input:new{
                        title = _("设备名称"),
                        fields = { { text = Settings.get("utils").device_name, hint = DeviceInfo.name() } },
                        ok_text = _("保存"),
                        callback = function(value) save(desktop, "device_name", Text.trim(value)) end,
                    }:show()
                end,
            })
        end,
        function(iw)
            local custom = Settings.get("utils").device_logo ~= ""
            return Row.widget({
                width = iw, kind = "nav", icon = "account_circle", title = _("设备头像"),
                subtitle = _("显示在锁屏密码界面左上角"),
                status = custom and _("自定义") or _("默认"), status_on = custom,
                callback = function()
                    local current = Settings.get("utils").device_logo
                    local dir = current:match("^(.*)/")
                    local home = require("apps/filemanager/filemanagerutil").getHomeFolder()
                    require("ui.themes.widgets.path_picker"):new{
                        path = dir and require("libs/libkoreader-lfs").attributes(dir, "mode") == "directory" and current or home,
                        select_file = true,
                        filter = function(name) return Image.suffix(name) ~= nil end,
                        on_select = function(path) save(desktop, "device_logo", path) end,
                    }:show()
                end,
            })
        end,
        function(iw)
            return Row.widget({
                width = iw, icon = "restart_alt", title = _("恢复默认头像"),
                enabled = Settings.get("utils").device_logo ~= "",
                callback = function() save(desktop, "device_logo", "") end,
            })
        end,
    }
end

return Device
