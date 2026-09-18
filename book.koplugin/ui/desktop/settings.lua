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
local TopbarSettings = require("ui.desktop.settings.topbar")
local Language = require("ui.desktop.settings.language")
local QuickPanel = require("ui.panel.settings")
local Maintenance = require("ui.desktop.settings.maintenance")
local AISettings = require("ui.desktop.settings.ai")
local ReaderSettings = require("ui.desktop.settings.reader")

local View = require("ui.view")
---@class BookSettings : View
---@field desktop BookDesktop
---@field page number
---@field sub string|nil
---@field parent string|nil
---@field source BookSettingsSource
---@field display BookSettingsDisplay
---@field lockscreen BookSettingsLockscreen
---@field desktop_settings BookSettingsDesktop
---@field topbar_settings BookSettingsTopbar
---@field language BookSettingsLanguage
---@field maintenance BookSettingsMaintenance
---@field ai BookSettingsAI
---@field reader BookSettingsReader
local Settings = {}
Settings.__index = Settings
setmetatable(Settings, View)

--- 创建设置页及其子设置对象；离屏实例不绑定屏幕刷新宿主。
---@param opts table 布局尺寸、样式及行为选项；缺省项使用组件默认值
---@return BookSettings
function Settings:new(opts)
    local view = View.new(self, opts)
    view.host = not view.offscreen and view.desktop or nil
    local defaults = {
        page = 1,
        sub = nil,
        parent = nil,
        source = Source.new(),
        display = Display.new(),
        lockscreen = Lockscreen.new(),
        desktop_settings = DesktopSettings.new(),
        topbar_settings = TopbarSettings.new(),
        language = Language.new(),
        maintenance = Maintenance.new(),
        ai = AISettings.new(),
        reader = ReaderSettings.new(),
    }
    for key, value in pairs(defaults) do
        if view[key] == nil then view[key] = value end
    end
    return view
end

--- 由 Tab 切换恢复时重置设置导航；系统唤醒时保留当前位置。
---@param changed boolean|nil TAB 点击时传 boolean；桌面唤醒时不重置设置位置
---@return nil
function Settings:onResume(changed)
    if changed == nil then return end
    self:reset()
    self.desktop._cache_size_label = nil
end

--- 回到设置根页并清除子页及父页导航记录。
---@return nil
function Settings:reset()
    self.page = 1
    self.sub = nil
    self.parent = nil
end

--- 换源后清除旧设置导航，避免停留在不适用的源子页。
---@param event string 父组件转发的事件名称或事件对象
---@return nil
function Settings:onEvent(event)
    if event == "source_changed" then
        self:reset()
    end
end

--- 进入指定设置子页并刷新桌面内容区域。
---@param sub string 要进入的设置子页标识
---@param parent string|nil 返回导航对应的父设置页标识
---@return nil
function Settings:showSub(sub, parent)
    self.sub = sub
    self.parent = parent
    self.page = 1
    self.desktop:updateView()
end

--- 设置行之间的留白，替代把每行切开的硬分割线。
---@return table widget 设置行之间的间隔控件
local function rowGap()
    return VerticalSpan:new{ width = UI.sz(6) }
end

--- 分组标题和行构建器展平进分页数据。
---@param out table 追加构建结果的控件数组
---@param width number 目标宽度，单位像素
---@param title string 显示标题
---@param row_builders table 返回设置行的构建函数数组
---@return nil
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
---@param desktop BookDesktop 所属桌面实例
---@param opts table 布局尺寸、样式及行为选项；缺省项使用组件默认值
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
            callback = function() desktop.settings:showSub(opts.sub) end,
        })
    end
end

--- 造子页顶部「返回」行的构造器。
---@param desktop BookDesktop 桌面实例
---@return fun(iw: number): table
local function backRow(desktop)
    return function(iw)
        return SettingRow.build(iw, {
            kind = "action", icon = "arrow_back", title = _("返回"),
            callback = function() desktop.settings:showSub(desktop.settings.parent) end,
        })
    end
end

--- 构建设置页主菜单或当前分类子页。
---@return table
function Settings:createWidget()
    local desktop = self.desktop
    local h, w = self.height or desktop:contentHeight(), self.width or desktop.dimen.w
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
    active_name = require("ui.desktop.settings.source").displayName(active_name)

    local packed = {}
    local sub = self.sub
    local valid_sub = {
        sources = true, reader = true, appearance = true, lockscreen = true,
        language = true, services = true, reader_popup = true,
        quickpanel_reader = true, quickpanel_desktop = true, topbar = true,
    }
    if sub ~= nil and not valid_sub[sub] then
        sub = nil
        self.sub = nil
        self.parent = nil
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
                subtitle = _("月读界面和首页顶栏"),
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
            self.maintenance:cacheRow(desktop),
            self.maintenance:debugLogRow(desktop),
            self.maintenance:autoUpdateRow(desktop),
            self.maintenance:updateRow(desktop),
            self.maintenance:aboutRow(),
            self.maintenance:closeRow(desktop),
        })
    else
        table.insert(packed, backRow(desktop)(card_w))
        if sub == "sources" then
            for _idx, section in ipairs(self.source:sections{
                desktop = desktop, plugin = plugin, active_id = active_id, active_name = active_name,
            }) do
                appendSection(packed, card_w, section.title, section.rows)
            end
        elseif sub == "reader" then
            for _, section in ipairs(self.reader:sections(desktop)) do
                appendSection(packed, card_w, section.title, section.rows)
            end
            appendSection(packed, card_w, _("菜单与快捷操作"), {
                function(iw)
                    return SettingRow.build(iw, {
                        kind = "nav", icon = "format_ink_highlighter", title = _("划词菜单"),
                        subtitle = _("设置选中文字后显示的操作和顺序"),
                        callback = function() desktop.settings:showSub("reader_popup", "reader") end,
                    })
                end,
                function(iw)
                    return SettingRow.build(iw, {
                        kind = "nav", icon = "dashboard_customize", title = _("阅读快捷面板"),
                        subtitle = _("设置阅读页顶部的快捷操作"),
                        status = T(_("已启用 %1 项"), QuickPanel.readerEnabledCount()), status_on = true,
                        callback = function() desktop.settings:showSub("quickpanel_reader", "reader") end,
                    })
                end,
            })
        elseif sub == "reader_popup" then
            appendSection(packed, card_w, _("划词菜单"), self.reader:popupRows(desktop))
        elseif sub == "appearance" then
            appendSection(packed, card_w, _("首页与启动"), self.desktop_settings:rows(desktop, open_on))
            appendSection(packed, card_w, _("快捷操作"), {
                function(iw)
                    return SettingRow.build(iw, {
                        kind = "nav", icon = "dashboard_customize", title = _("桌面快捷面板"),
                        subtitle = _("设置月读桌面顶部的快捷操作"),
                        status = T(_("已启用 %1 项"), QuickPanel.desktopEnabledCount()), status_on = true,
                        callback = function() desktop.settings:showSub("quickpanel_desktop", "appearance") end,
                    })
                end,
            })
            appendSection(packed, card_w, _("界面显示"), self.display:rows{
                desktop = desktop, font_name = font_name, scale = scale, grid_max_cols = grid_max_cols,
            })
        elseif sub == "lockscreen" then
            appendSection(packed, card_w, _("锁屏"), self.lockscreen:rows(desktop))
        elseif sub == "topbar" then
            appendSection(packed, card_w, _("首页顶栏"), self.topbar_settings:rows(desktop))
        elseif sub == "language" then
            appendSection(packed, card_w, _("语言与输入"), self.language:rows(desktop))
        elseif sub == "quickpanel_reader" then
            appendSection(packed, card_w, _("阅读快捷面板"), QuickPanel.readerRows(desktop))
        elseif sub == "quickpanel_desktop" then
            appendSection(packed, card_w, _("桌面快捷面板"), QuickPanel.desktopRows(desktop))
        elseif sub == "services" then
            appendSection(packed, card_w, _("AI 服务"), self.ai:rows(desktop))
            appendSection(packed, card_w, _("远程管理"), RemoteUI.menuRows(desktop))
        end
    end

    local pages_kids = Pager.pack(packed, pack_h)
    local pages = #pages_kids
    local page = Pager.clamp(self.page, pages)
    self.page = page
    local page_body = FrameContainer:new{
        bordersize = 0, padding = page_pad, padding_bottom = bottom_pad, margin = 0,
        background = Blitbuffer.COLOR_WHITE, dimen = Geom:new{ w = w, h = body_h },
        VerticalGroup:new(pages_kids[page]),
    }
    return (select(1, Pager.frame(w, h, {
        body = page_body, page = page, pages = pages,
        handlers = {
            on_prev = function() self.page = page - 1; desktop:updateView() end,
            on_next = function() self.page = page + 1; desktop:updateView() end,
            on_first = function() self.page = 1; desktop:updateView() end,
            on_last = function() self.page = pages; desktop:updateView() end,
        },
    })))
end

--- 一生一次：首帧设置页。
---@return table
function Settings:updateView()
    return self:rebuild()
end

return Settings
