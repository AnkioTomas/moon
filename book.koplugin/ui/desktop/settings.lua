--[[--
设置页编排：主菜单、分类路由与分页。

各设置项位于 ui/desktop/settings/，本文件不拥有分类业务逻辑。

@module koplugin.book.ui.desktop.settings
--]]

local Blitbuffer = require("ffi/blitbuffer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local LeftContainer = require("ui/widget/container/leftcontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local TextWidget = require("ui/widget/textwidget")
local UI = require("ui.components.bookui")
local Pager = require("ui.components.pager")
local SettingRow = require("ui.components.settingrow")
local MoonSettings = require("utils.settings")
local MoonFont = require("utils.font")
local LockSettings = require("lockscreen.settings")
local Remote = require("remote.init")
local RemoteUI = require("remote.ui")
local SourceRegistry = require("source.registry")
local Host = require("host")
local _ = require("gettext")
local T = require("ffi/util").template

local Source = require("ui.desktop.settings.source")
local Display = require("ui.desktop.settings.display")
local Lockscreen = require("ui.desktop.settings.lockscreen")
local DesktopSettings = require("ui.desktop.settings.desktop")
local HomeSettings = require("ui.desktop.settings.home")
local TopbarSettings = require("ui.desktop.settings.topbar")
local Language = require("ui.desktop.settings.language")
local QuickPanel = require("ui.panel.settings")
local Maintenance = require("ui.desktop.settings.maintenance")
local AISettings = require("ui.desktop.settings.ai")
local ReaderSettings = require("ui.desktop.settings.reader")

local Settings = {}

--- 设置行之间的留白，替代把每行切开的硬分割线。
local function rowGap()
    return VerticalSpan:new{ width = UI.sz(6) }
end

--- 分组标题和行构建器展平进分页数据。
---@param out table
---@param width number
---@param title string
---@param row_builders table
local function appendSection(out, width, title, row_builders)
    if #out > 0 then table.insert(out, VerticalSpan:new{ width = UI.sectionGap() }) end
    table.insert(out, LeftContainer:new{
        dimen = Geom:new{ w = width, h = UI.sz(28) },
        TextWidget:new{ text = title, face = UI.face("cfont", 13), max_width = width, fgcolor = UI.muted() },
    })
    for i, build in ipairs(row_builders) do
        if i > 1 then table.insert(out, rowGap()) end
        table.insert(out, build(width))
    end
end

--- 造主设置页的分类导航行。
---@param desktop table
---@param opts table
---@return fun(iw: number): table
local function categoryRow(desktop, opts)
    return function(iw)
        return SettingRow.build(iw, {
            kind = "nav",
            icon = opts.icon,
            title = opts.title,
            subtitle = opts.subtitle,
            status = opts.status,
            status_on = opts.status_on,
            callback = function() desktop:showSettingsSub(opts.sub) end,
        })
    end
end

--- 造子页顶部「返回」行的构造器。
---@param desktop table 桌面实例
---@return fun(iw: number): table
local function backRow(desktop)
    return function(iw)
        return SettingRow.build(iw, {
            kind = "action", icon = "arrow_back", title = _("返回"),
            callback = function() desktop:showSettingsSub(desktop._settings_parent) end,
        })
    end
end

--- 构建设置页主菜单或当前分类子页。
---@param desktop table
---@return table
function Settings.build(desktop)
    local h, w = desktop:contentHeight(), desktop.dimen.w
    local plugin = desktop.plugin
    local open_on = G_reader_settings:readSetting("start_with") == Host.OPEN_ON_START_ID
    local scale, grid_max_cols = UI.getScale(), UI.getGridMaxCols()
    local font_name = MoonFont.currentName()
    local page_pad = UI.pagePad()
    local card_w = math.max(UI.sz(100), w - page_pad * 2)
    local band_h = Pager.bandH()
    local body_h = math.max(1, h - band_h)
    local bottom_pad = UI.sz(4)
    local pack_h = math.max(1, body_h - page_pad - bottom_pad)

    local active_id = MoonSettings.activeSourceId()
    local active_name = active_id
    for _idx, meta in ipairs(SourceRegistry.list()) do
        if meta.id == active_id then active_name = meta.name or meta.id break end
    end

    local packed = {}
    local sub = desktop._settings_sub
    local valid_sub = {
        sources = true, reader = true, appearance = true, lockscreen = true,
        language = true, services = true, reader_popup = true,
        quickpanel_reader = true, quickpanel_desktop = true, home = true, topbar = true,
    }
    if sub ~= nil and not valid_sub[sub] then
        sub = nil
        desktop._settings_sub = nil
        desktop._settings_parent = nil
    end

    if sub == nil then
        appendSection(packed, card_w, _("功能设置"), {
            categoryRow(desktop, {
                sub = "sources", icon = "source", title = _("书库与账号"),
                subtitle = _("切换书籍来源，管理账号和本地目录"),
                status = active_name, status_on = true,
            }),
            categoryRow(desktop, {
                sub = "reader", icon = "menu_book", title = _("阅读与工具"),
                subtitle = _("阅读界面、划词工具和快捷操作"),
            }),
            categoryRow(desktop, {
                sub = "appearance", icon = "display_settings", title = _("界面与首页"),
                subtitle = _("月读界面、首页组件和首页顶栏"),
                status = string.format("%d%%", scale), status_on = true,
            }),
            categoryRow(desktop, {
                sub = "lockscreen", icon = "wallpaper", title = _("锁屏"),
                status = LockSettings.isCompose() and _("开") or _("关"),
                status_on = LockSettings.isCompose(),
            }),
            categoryRow(desktop, {
                sub = "language", icon = "language", title = _("语言与输入"),
                status = require("ui/language"):getLanguageName(G_reader_settings:readSetting("language") or "C"),
                status_on = true,
            }),
            categoryRow(desktop, {
                sub = "services", icon = "dns", title = _("连接与服务"),
                subtitle = _("AI 服务和远程管理"),
                status = Remote.isRunning() and _("运行中") or nil,
                status_on = Remote.isRunning(),
            }),
        })
        appendSection(packed, card_w, _("维护与信息"), {
            Maintenance.cacheRow(desktop),
            Maintenance.debugLogRow(desktop),
            Maintenance.autoUpdateRow(desktop),
            Maintenance.updateRow(desktop),
            Maintenance.aboutRow(),
            Maintenance.closeRow(desktop),
        })
    else
        table.insert(packed, backRow(desktop)(card_w))
        if sub == "sources" then
            for _idx, section in ipairs(Source.sections{
                desktop = desktop, plugin = plugin, active_id = active_id, active_name = active_name,
            }) do
                appendSection(packed, card_w, section.title, section.rows)
            end
        elseif sub == "reader" then
            for _, section in ipairs(ReaderSettings.sections(desktop)) do
                appendSection(packed, card_w, section.title, section.rows)
            end
            appendSection(packed, card_w, _("菜单与快捷操作"), {
                function(iw)
                    return SettingRow.build(iw, {
                        kind = "nav", icon = "format_ink_highlighter", title = _("划词菜单"),
                        subtitle = _("设置选中文字后显示的操作和顺序"),
                        callback = function() desktop:showSettingsSub("reader_popup", "reader") end,
                    })
                end,
                function(iw)
                    return SettingRow.build(iw, {
                        kind = "nav", icon = "dashboard_customize", title = _("阅读快捷面板"),
                        subtitle = _("设置阅读页顶部的快捷操作"),
                        status = T(_("已启用 %1 项"), QuickPanel.readerEnabledCount()), status_on = true,
                        callback = function() desktop:showSettingsSub("quickpanel_reader", "reader") end,
                    })
                end,
            })
        elseif sub == "reader_popup" then
            appendSection(packed, card_w, _("划词菜单"), ReaderSettings.popupRows(desktop))
        elseif sub == "appearance" then
            appendSection(packed, card_w, _("首页与启动"), DesktopSettings.rows(desktop, open_on))
            appendSection(packed, card_w, _("快捷操作"), {
                function(iw)
                    return SettingRow.build(iw, {
                        kind = "nav", icon = "dashboard_customize", title = _("桌面快捷面板"),
                        subtitle = _("设置月读桌面顶部的快捷操作"),
                        status = T(_("已启用 %1 项"), QuickPanel.desktopEnabledCount()), status_on = true,
                        callback = function() desktop:showSettingsSub("quickpanel_desktop", "appearance") end,
                    })
                end,
            })
            appendSection(packed, card_w, _("界面显示"), Display.rows{
                desktop = desktop, font_name = font_name, scale = scale, grid_max_cols = grid_max_cols,
            })
        elseif sub == "lockscreen" then
            appendSection(packed, card_w, _("锁屏"), Lockscreen.rows(desktop))
        elseif sub == "topbar" then
            appendSection(packed, card_w, _("首页顶栏"), TopbarSettings.rows(desktop))
        elseif sub == "home" then
            for _idx, section in ipairs(HomeSettings.sections(desktop)) do
                appendSection(packed, card_w, section.title, section.rows)
            end
        elseif sub == "language" then
            appendSection(packed, card_w, _("语言与输入"), Language.rows(desktop))
        elseif sub == "quickpanel_reader" then
            appendSection(packed, card_w, _("阅读快捷面板"), QuickPanel.readerRows(desktop))
        elseif sub == "quickpanel_desktop" then
            appendSection(packed, card_w, _("桌面快捷面板"), QuickPanel.desktopRows(desktop))
        elseif sub == "services" then
            appendSection(packed, card_w, _("AI 服务"), AISettings.rows(desktop))
            appendSection(packed, card_w, _("远程管理"), RemoteUI.menuRows(desktop))
        end
    end

    local pages_kids = Pager.pack(packed, pack_h)
    local pages = #pages_kids
    local page = Pager.clamp(desktop._settings_page, pages)
    desktop._settings_page = page
    local page_body = FrameContainer:new{
        bordersize = 0, padding = page_pad, padding_bottom = bottom_pad, margin = 0,
        background = Blitbuffer.COLOR_WHITE, dimen = Geom:new{ w = w, h = body_h },
        VerticalGroup:new(pages_kids[page]),
    }
    return (select(1, Pager.frame(w, h, {
        body = page_body, page = page, pages = pages,
        handlers = {
            on_prev = function() desktop._settings_page = page - 1; desktop:rebuild() end,
            on_next = function() desktop._settings_page = page + 1; desktop:rebuild() end,
            on_first = function() desktop._settings_page = 1; desktop:rebuild() end,
            on_last = function() desktop._settings_page = pages; desktop:rebuild() end,
        },
    })))
end

return Settings
