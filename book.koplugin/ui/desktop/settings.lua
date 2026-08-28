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
local LockScreen = require("lockscreen.init")
local Remote = require("remote.init")
local SourceRegistry = require("source.registry")
local Host = require("host")
local _ = require("gettext")
local T = require("ffi/util").template

local Source = require("ui.desktop.settings.source")
local Display = require("ui.desktop.settings.display")
local Lockscreen = require("ui.desktop.settings.lockscreen")
local DesktopSettings = require("ui.desktop.settings.desktop")
local HomeSettings = require("ui.desktop.settings.home")
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

---@param out table
---@param width number
---@param row_builders table
local function appendRowList(out, width, row_builders)
    for i, build in ipairs(row_builders) do
        if i > 1 then table.insert(out, rowGap()) end
        table.insert(out, build(width))
    end
end

--- 切换设置子页并重建；页码重置到第一页。
---@param desktop table 桌面实例
---@param sub string|nil 子页标识；nil 回到设置主菜单
local function gotoSub(desktop, sub)
    desktop._settings_sub = sub
    desktop._settings_page = 1
    desktop:rebuild()
end

--- 造子页顶部「返回」行的构造器。
---@param desktop table 桌面实例
---@return fun(iw: number): table
local function backRow(desktop)
    return function(iw)
        return SettingRow.build(iw, {
            kind = "action", icon = "arrow_back", title = _("返回"),
            callback = function() gotoSub(desktop, nil) end,
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

    local active_id = MoonSettings.activeSourceId()
    local active_name = active_id
    for _idx, meta in ipairs(SourceRegistry.list()) do
        if meta.id == active_id then active_name = meta.name or meta.id break end
    end

    local packed = {}
    local sub = desktop._settings_sub
    local valid_sub = {
        sources = true, display = true, lockscreen = true, desktop = true,
        home = true, language = true, remote = true, quickpanel = true, ai = true,
        reader = true,
    }
    if sub ~= nil and not valid_sub[sub] then
        sub = nil
        desktop._settings_sub = nil
    end

    if sub == nil then
        appendRowList(packed, card_w, {
            function(iw)
                return SettingRow.build(iw, {
                    kind = "nav", icon = "source", title = _("数据源"), status = active_name, status_on = true,
                    callback = function() gotoSub(desktop, "sources") end,
                })
            end,
            function(iw)
                return SettingRow.build(iw, {
                    kind = "nav", icon = "menu_book", title = _("阅读"),
                    status_on = true,
                    callback = function() gotoSub(desktop, "reader") end,
                })
            end,
            function(iw)
                return SettingRow.build(iw, {
                    kind = "nav", icon = "display_settings", title = _("显示"),
                    status = string.format("%d%%", scale), status_on = true,
                    callback = function() gotoSub(desktop, "display") end,
                })
            end,
            function(iw)
                return SettingRow.build(iw, {
                    kind = "nav", icon = "wallpaper", title = _("锁屏"),
                    status = LockScreen.isCompose() and _("开") or _("关"),
                    status_on = LockScreen.isCompose(),
                    callback = function() gotoSub(desktop, "lockscreen") end,
                })
            end,
            function(iw)
                return SettingRow.build(iw, {
                    kind = "nav", icon = "desktop_windows", title = _("桌面"),
                    status = open_on and _("开") or _("关"), status_on = open_on,
                    callback = function() gotoSub(desktop, "desktop") end,
                })
            end,
            function(iw)
                return SettingRow.build(iw, {
                    kind = "nav", icon = "language", title = _("语言与输入"),
                    status = require("ui/language"):getLanguageName(G_reader_settings:readSetting("language") or "C"),
                    status_on = true, callback = function() gotoSub(desktop, "language") end,
                })
            end,
            function(iw)
                local configured = require("ai").isConfigured()
                return SettingRow.build(iw, {
                    kind = "nav", icon = "psychology", title = _("AI 服务"),
                    status = configured and MoonSettings.get().ai_model or _("未配置"),
                    status_on = configured,
                    callback = function() gotoSub(desktop, "ai") end,
                })
            end,
            function(iw)
                return SettingRow.build(iw, {
                    kind = "nav", icon = "folder", title = _("远程管理"),
                    status = Remote.isRunning() and _("运行中") or nil, status_on = Remote.isRunning(),
                    callback = function() gotoSub(desktop, "remote") end,
                })
            end,
            function(iw)
                return SettingRow.build(iw, {
                    kind = "nav", icon = "dashboard_customize", title = _("快捷面板"),
                    status = T(_("已启用 %1 项"), QuickPanel.enabledCount()), status_on = true,
                    callback = function() gotoSub(desktop, "quickpanel") end,
                })
            end,
            Maintenance.cacheRow(desktop),
            Maintenance.importNotesRow(),
            Maintenance.importStatsRow(),
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
        elseif sub == "display" then
            appendSection(packed, card_w, _("显示"), Display.rows{
                desktop = desktop, font_name = font_name, scale = scale, grid_max_cols = grid_max_cols,
            })
        elseif sub == "lockscreen" then
            appendSection(packed, card_w, _("锁屏"), Lockscreen.rows(desktop))
        elseif sub == "desktop" then
            appendSection(packed, card_w, _("桌面"), DesktopSettings.rows(desktop, open_on))
        elseif sub == "home" then
            for _idx, section in ipairs(HomeSettings.sections(desktop)) do
                appendSection(packed, card_w, section.title, section.rows)
            end
        elseif sub == "language" then
            appendSection(packed, card_w, _("语言与输入"), Language.rows(desktop))
        elseif sub == "remote" then
            appendSection(packed, card_w, _("远程管理"), Remote.menuRows(desktop))
        elseif sub == "quickpanel" then
            for _, section in ipairs(QuickPanel.sections(desktop)) do
                appendSection(packed, card_w, section.title, section.rows)
            end
        elseif sub == "ai" then
            appendSection(packed, card_w, _("AI 服务"), AISettings.rows(desktop))
        elseif sub == "reader" then
            for _, section in ipairs(ReaderSettings.sections(desktop)) do
                appendSection(packed, card_w, section.title, section.rows)
            end
        end
    end

    local pages_kids = Pager.pack(packed, body_h)
    local pages = #pages_kids
    local page = Pager.clamp(desktop._settings_page, pages)
    desktop._settings_page = page
    local page_body = FrameContainer:new{
        bordersize = 0, padding = page_pad, padding_bottom = UI.sz(4), margin = 0,
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
