--[[--
设置页编排：根页功能目录，子页走详情叠层。

各设置项位于 ui/desktop/settings/，本文件不拥有分类业务逻辑。

@module koplugin.book.ui.desktop.settings
--]]

local Blitbuffer = require("ffi/blitbuffer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local VerticalGroup = require("ui/widget/verticalgroup")
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
local Overlay = require("ui.desktop.settings.overlay")
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
local ReaderBarSettings = require("ui.desktop.settings.reader_bar")

local View = require("ui.view")
---@class BookSettings : View
---@field desktop BookDesktop
---@field page number
---@field source BookSettingsSource 顶栏点源名经此换源
local Settings = {}
Settings.__index = Settings
setmetatable(Settings, View)

--- 创建设置页；离屏实例不绑定屏幕刷新宿主。
---@param opts table 布局尺寸、样式及行为选项；缺省项使用组件默认值
---@return BookSettings
function Settings:new(opts)
    local view = View.new(self, opts)
    view.host = not view.offscreen and view.desktop or nil
    view.page = view.page or 1
    view.source = view.source or Source
    return view
end

--- 由 Tab 切换恢复时关掉叠层；系统唤醒时保留。
---@param changed boolean|nil TAB 点击时传 boolean；桌面唤醒时不重置
function Settings:onResume(changed)
    if changed == nil then return end
    self:reset()
    self.desktop._cache_size_label = nil
end

--- 回到设置根页并关闭功能叠层。
function Settings:reset()
    self.page = 1
    Overlay.close(self.desktop)
end

--- 换源后关掉叠层，避免停在过期的来源页。
---@param event string 父组件转发的事件名称或事件对象
function Settings:onEvent(event)
    if event == "source_changed" then
        self:reset()
    end
end

---@param settings BookSettings
---@return string, string
local function activeSource()
    local active_id = MoonSettings.activeSourceId()
    local active_name = active_id
    for _idx, meta in ipairs(SourceRegistry.list()) do
        if meta.id == active_id then active_name = meta.name or meta.id break end
    end
    return active_id, Source.displayName(active_name)
end

--- 功能叠层规格。preview 只给有可视化的页；sections 每次重建都重算。
---@param self BookSettings
---@param id string
---@return BookSettingsOverlaySpec|nil
function Settings:spec(id)
    local desktop = self.desktop
    local plugin = desktop.plugin
    if id == "sources" then
        local active_id, active_name = activeSource()
        return {
            id = id,
            title = _("书籍来源"),
            sections = function()
                return Source:scopeSections{
                    desktop = desktop, plugin = plugin, active_id = active_id, active_name = active_name,
                }
            end,
        }
    end
    if id == "source_config" then
        return {
            id = id,
            title = _("账号与登录"),
            sections = function()
                return Source:configSections{ desktop = desktop, plugin = plugin }
            end,
        }
    end
    if id == "reader_top" or id == "reader_bottom" then
        local which = id == "reader_top" and "top" or "bottom"
        return {
            id = id,
            title = which == "top" and _("阅读页顶栏") or _("阅读页底栏"),
            preview = function(width)
                return ReaderBarSettings:page(desktop, which).preview(width)
            end,
            sections = function()
                return ReaderBarSettings:page(desktop, which).sections
            end,
        }
    end
    if id == "reader_behavior" then
        return {
            id = id,
            title = _("阅读行为"),
            sections = function()
                return ReaderSettings:sections(desktop)
            end,
        }
    end
    if id == "lookup" then
        return {
            id = id,
            title = _("划词与查询"),
            sections = function()
                local sections = ReaderSettings:lookupSections(desktop)
                sections[#sections + 1] = { title = _("菜单"), rows = ReaderSettings:popupRows(desktop) }
                return sections
            end,
        }
    end
    if id == "quickpanel_desktop" or id == "quickpanel_reader" then
        local scope = id == "quickpanel_reader" and "reader" or "desktop"
        return {
            id = id,
            title = scope == "reader" and _("阅读快捷面板") or _("桌面快捷面板"),
            preview = function(width)
                return QuickPanel.preview(scope, width)
            end,
            sections = function()
                if scope == "reader" then
                    return {{ title = _("阅读"), rows = QuickPanel.readerRows(desktop) }}
                end
                return {{ title = _("桌面"), rows = QuickPanel.desktopRows(desktop) }}
            end,
        }
    end
    if id == "topbar" then
        return {
            id = id,
            title = _("桌面顶栏"),
            preview = function(width)
                return TopbarSettings.preview(width)
            end,
            sections = function()
                return {{ title = _("顶栏"), rows = TopbarSettings:rows(desktop) }}
            end,
        }
    end
    if id == "display" then
        return {
            id = id,
            title = _("界面显示"),
            sections = function()
                local scale, grid_max_cols = UI.getScale(), UI.getGridMaxCols()
                local font_name = MoonFont.currentName()
                local open_on = G_reader_settings:readSetting("start_with") == Host.OPEN_ON_START_ID
                return {
                    { title = _("启动"), rows = DesktopSettings:rows(desktop, open_on) },
                    {
                        title = _("显示"),
                        rows = Display:rows{
                            desktop = desktop, font_name = font_name, scale = scale, grid_max_cols = grid_max_cols,
                        },
                    },
                }
            end,
        }
    end
    if id == "lockscreen" then
        return {
            id = id,
            title = _("锁屏壁纸"),
            preview = function(width)
                return Lockscreen.preview(width)
            end,
            sections = function()
                return {{ title = _("锁屏"), rows = Lockscreen:rows(desktop) }}
            end,
        }
    end
    if id == "language" then
        return {
            id = id,
            title = _("语言与输入法"),
            sections = function()
                return Language:sections(desktop)
            end,
        }
    end
    if id == "ai" then
        return {
            id = id,
            title = _("AI 接口"),
            sections = function()
                return {{ title = _("AI"), rows = AISettings:rows(desktop) }}
            end,
        }
    end
    if id == "remote" then
        return {
            id = id,
            title = _("远程管理"),
            sections = function()
                return {{ title = _("远程"), rows = RemoteUI.menuRows(desktop) }}
            end,
        }
    end
    return nil
end

--- 打开指定功能叠层。
---@param id string
function Settings:open(id)
    local spec = self:spec(id)
    if spec then Overlay.open(self.desktop, spec) end
end

--- 造根页功能入口。
---@param desktop BookDesktop
---@param opts table
---@return fun(iw: number): table
local function featureRow(desktop, opts)
    return function(iw)
        return SettingRow.build(iw, {
            kind = "nav",
            icon = opts.icon,
            title = opts.title,
            subtitle = opts.subtitle,
            status = opts.status,
            status_on = opts.status_on,
            callback = function() desktop.settings:open(opts.id) end,
        })
    end
end

--- 构建设置根页。
---@return table
function Settings:createWidget()
    local desktop = self.desktop
    local h, w = self.height or desktop:contentHeight(), self.width or desktop.dimen.w
    local page_pad = UI.pagePad()
    local card_w = math.max(UI.sz(100), w - page_pad * 2)
    local band_h = Pager.bandH()
    local body_h = math.max(1, h - band_h)
    local bottom_pad = UI.sz(4)
    local pack_h = math.max(1, body_h - page_pad - bottom_pad)

    local active_name = select(2, activeSource())
    local scale = UI.getScale()
    local packed = {}
    Overlay.appendSection(packed, card_w, _("书库"), {
        featureRow(desktop, {
            id = "sources", icon = "source", title = _("书籍来源"),
            subtitle = _("切换和启用书源"),
            status = active_name, status_on = true,
        }),
        featureRow(desktop, {
            id = "source_config", icon = "tune", title = _("账号与登录"),
            subtitle = _("书源账号、本地书籍目录"),
        }),
    })
    Overlay.appendSection(packed, card_w, _("桌面"), {
        featureRow(desktop, {
            id = "display", icon = "display_settings", title = _("界面显示"),
            subtitle = _("字体缩放、夜间、亮度"),
            status = string.format("%d%%", scale), status_on = true,
        }),
        featureRow(desktop, {
            id = "topbar", icon = "toolbar", title = _("桌面顶栏"),
            subtitle = _("时钟、电量等状态项"),
        }),
        featureRow(desktop, {
            id = "lockscreen", icon = "wallpaper", title = _("锁屏壁纸"),
            subtitle = _("替代系统锁屏"),
            status = LockSettings.isCompose() and _("开") or _("关"),
            status_on = LockSettings.isCompose(),
        }),
        featureRow(desktop, {
            id = "quickpanel_desktop", icon = "dashboard_customize", title = _("桌面快捷面板"),
            subtitle = _("面板开关与顺序"),
            status = T(_("已启用 %1 项"), QuickPanel.desktopEnabledCount()),
            status_on = true,
        }),
    })
    Overlay.appendSection(packed, card_w, _("阅读"), {
        featureRow(desktop, {
            id = "reader_top", icon = "vertical_align_top", title = _("阅读页顶栏"),
            subtitle = _("页面顶部的信息组件"),
        }),
        featureRow(desktop, {
            id = "reader_bottom", icon = "horizontal_rule", title = _("阅读页底栏"),
            subtitle = _("进度条、百分比等"),
        }),
        featureRow(desktop, {
            id = "reader_behavior", icon = "touch_app", title = _("阅读行为"),
            subtitle = _("脚注弹窗、翻页动画、自动标记已读"),
        }),
        featureRow(desktop, {
            id = "lookup", icon = "format_ink_highlighter", title = _("划词与查询"),
            subtitle = _("翻译、词典、百科、X-Ray、划词菜单"),
        }),
        featureRow(desktop, {
            id = "quickpanel_reader", icon = "dashboard_customize", title = _("阅读快捷面板"),
            subtitle = _("面板按钮与顺序"),
            status = T(_("已启用 %1 项"), QuickPanel.readerEnabledCount()),
            status_on = true,
        }),
    })
    Overlay.appendSection(packed, card_w, _("系统"), {
        featureRow(desktop, {
            id = "language", icon = "language", title = _("语言与输入法"),
            subtitle = _("界面语言、中文输入法"),
            status = require("ui/language"):getLanguageName(G_reader_settings:readSetting("language") or "C"),
            status_on = true,
        }),
        featureRow(desktop, {
            id = "ai", icon = "psychology", title = _("AI 接口"),
            subtitle = _("X-Ray 使用的大模型接口"),
        }),
        featureRow(desktop, {
            id = "remote", icon = "dns", title = _("远程管理"),
            subtitle = _("浏览器管理文件、输入"),
            status = Remote.isRunning() and _("运行中") or nil,
            status_on = Remote.isRunning(),
        }),
    })
    Overlay.appendSection(packed, card_w, _("维护"), {
        Maintenance:cacheRow(desktop),
        Maintenance:clearStatsRow(desktop),
        Maintenance:debugLogRow(desktop),
        Maintenance:autoUpdateRow(desktop),
        Maintenance:updateRow(desktop),
        Maintenance:aboutRow(),
        Maintenance:closeRow(desktop),
    })

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
