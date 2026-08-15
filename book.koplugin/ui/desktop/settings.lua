--[[--
设置页 UI（桌面 Tab）
  通用：数据源切换 / 显示与启动 / 维护 / 测试连接
  源专属：source.<id>.setting.open 自绘；本页只画入口行

布局（SettingRow 列表 + Pager.frame）：
  +-----------------------------------------------+
  | 数据源                                        |
  | [icon] 当前源名                        ›      |
  | [icon] 源专属设置…                     ›      |
  | 显示与启动                                    |
  | [icon] 界面字体                        ›      |
  | [icon] 字号                            130% › |
  | [icon] 启动打开桌面                      开   |
  | 维护                                          |
  | [icon] 清理缓存                         12M   |
  | [icon] 关于                         1.2.3 ›  |
  | [icon] 关闭桌面                               |
  |  |«  ‹   Page N of M   ›  »|                  |
  +-----------------------------------------------+

@module koplugin.book.ui.settings
--]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local NetworkMgr = require("ui/network/manager")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local TextWidget = require("ui/widget/textwidget")
local UI = require("ui.components.bookui")
local Icon = require("ui.components.icon")
local Pager = require("ui.components.pager")
local Popup = require("ui.components.popup")
local SettingRow = require("ui.components.settingrow")
local FontPicker = require("ui.components.fontpicker")
local MoonSettings = require("utils.settings")
local MoonFont = require("utils.font")
local SourceRegistry = require("source.registry")
local StatsSync = require("stats.stats_sync")
local Cache = require("book.cache")
local Host = require("host")
local _ = require("gettext")
local T = require("ffi/util").template

local REPO_URL = "https://github.com/AnkioTomas/moon"
local REPO_HOST = "github.com/AnkioTomas/moon"

--- 读取插件版本号（bookversion 模块）。
---@return string
local function pluginVersion()
    local ok, ver = pcall(require, "bookversion")
    if ok and type(ver) == "string" and ver ~= "" then
        return ver
    end
    return "0.0.0-dev"
end

--- 弹出关于对话框。
local function showAbout()
    local ver = pluginVersion()
    local dialog
    local buttons = {}
    if Device:canOpenLink() then
        buttons[#buttons + 1] = {{
            text = _("打开 GitHub"),
            callback = function()
                Device:openLink(REPO_URL)
            end,
        }}
    end
    buttons[#buttons + 1] = {{
        text = _("关闭"),
        callback = function()
            UIManager:close(dialog)
        end,
    }}

    dialog = ButtonDialog:new{
        title = _("关于"),
        title_align = "center",
        use_info_style = false,
        buttons = buttons,
    }

    local avail_w = dialog:getAddedWidgetAvailableWidth()
    local body = VerticalGroup:new{ align = "center" }
    local icon = Icon.widget{
        name = "info",
        size = 44,
    }
    if icon then
        table.insert(body, icon)
        table.insert(body, VerticalSpan:new{ width = UI.sz(10) })
    end
    table.insert(body, TextWidget:new{
        text = _("Book 书库"),
        face = UI.face("cfont", 20),
    })
    table.insert(body, VerticalSpan:new{ width = UI.sz(4) })
    table.insert(body, TextWidget:new{
        text = T(_("版本 %1"), ver),
        face = UI.face("xx_smallinfofont", 13),
        fgcolor = UI.muted(),
    })
    table.insert(body, VerticalSpan:new{ width = UI.sz(12) })
    table.insert(body, TextBoxWidget:new{
        text = _("面向 KOReader 的书库桌面，支持多数据源与阅读进度同步。"),
        face = UI.face("xx_smallinfofont", 13),
        width = avail_w,
        alignment = "center",
        fgcolor = UI.dim(),
    })
    table.insert(body, VerticalSpan:new{ width = UI.sz(14) })
    table.insert(body, TextWidget:new{
        text = "AnkioTomas",
        face = UI.face("cfont", 14),
    })
    table.insert(body, VerticalSpan:new{ width = UI.sz(2) })
    table.insert(body, TextWidget:new{
        text = REPO_HOST,
        face = UI.face("xx_smallinfofont", 12),
        fgcolor = UI.muted(),
    })
    table.insert(body, VerticalSpan:new{ width = UI.sz(4) })
    table.insert(body, TextWidget:new{
        text = _("MIT License"),
        face = UI.face("xx_smallinfofont", 11),
        fgcolor = UI.muted(),
    })

    dialog:addWidget(body)
    UIManager:show(dialog)
end

local Settings = {}

--- 按源 id 加载 source.<id>.setting 模块。
---@param id string
---@return table|nil
local function loadSourceSetting(id)
    local ok, mod = pcall(require, "source." .. tostring(id) .. ".setting")
    if ok and type(mod) == "table" then
        return mod
    end
    return nil
end

--- 在线测试当前数据源连接。
---@param plugin table|nil
local function testConnection(plugin)
    if not plugin or not plugin.getSource then
        return
    end
    NetworkMgr:runWhenOnline(function()
        local source = plugin:getSource()
        if not source or not source.pingAsync then
            UIManager:show(InfoMessage:new{ text = _("连接失败") })
            return
        end
        source:pingAsync(function(res, err)
            if not res then
                UIManager:show(InfoMessage:new{
                    text = err or _("连接失败"),
                })
                return
            end
            local name = res.data and (res.data.display_name or res.data.username) or "?"
            UIManager:show(InfoMessage:new{
                text = T(_("连接成功：%1"), name),
                timeout = 3,
            })
        end)
    end)
end

--- 设置分组内的缩进分割线。
---@param width number
---@return table
local function insetDivider(width)
    local inset = UI.sz(8)
    local line_w = math.max(UI.sz(40), width - inset * 2)
    return CenterContainer:new{
        dimen = Geom:new{ w = width, h = UI.line() },
        LineWidget:new{
            background = UI.rule(),
            dimen = Geom:new{ w = line_w, h = UI.line() },
        },
    }
end

--- 分组标题 + 各行展平进 out；标题与 item 同等参与 Pager.pack 切页。
---@param out table
---@param width number
---@param title string
---@param row_builders table
local function appendSection(out, width, title, row_builders)
    if #out > 0 then
        table.insert(out, VerticalSpan:new{ width = UI.sectionGap() })
    end
    table.insert(out, LeftContainer:new{
        dimen = Geom:new{ w = width, h = UI.sz(28) },
        TextWidget:new{
            text = title,
            face = UI.face("cfont", 13),
            max_width = width,
            fgcolor = UI.muted(),
        },
    })
    for i, build in ipairs(row_builders) do
        if i > 1 then
            table.insert(out, insetDivider(width))
        end
        table.insert(out, build(width))
    end
end

--- 当前源专属入口 + 通用测试连接 / 同步 / 统计上报。
---@param active_id string
---@param plugin table|nil
---@return table
local function sourceServiceRows(active_id, plugin)
    local mod = loadSourceSetting(active_id)
    local rows = {}
    local source = plugin and plugin.getSource and plugin:getSource() or nil
    local caps = source and source.capabilities and source:capabilities() or {}

    if mod and type(mod.open) == "function" then
        local status, status_on
        if type(mod.rowStatus) == "function" then
            status, status_on = mod.rowStatus()
        end
        rows[#rows + 1] = function(iw)
            return SettingRow.build(iw, {
                kind = "nav",
                icon = (mod.rowIcon and mod.rowIcon()) or "dns",
                title = (mod.rowTitle and mod.rowTitle()) or _("配置"),
                status = status,
                status_on = status_on,
                callback = function()
                    mod.open(plugin)
                end,
            })
        end
    end

    if type(source and source.importBookAsync) == "function" then
        local store_setting = require("zlib.setting")
        local status, status_on = store_setting.rowStatus()
        rows[#rows + 1] = function(iw)
            return SettingRow.build(iw, {
                kind = "nav",
                icon = "storefront",
                title = _("Z-Library 账号"),
                status = status,
                status_on = status_on,
                callback = function()
                    store_setting.open(plugin)
                end,
            })
        end
    end

    rows[#rows + 1] = function(iw)
        return SettingRow.build(iw, {
            kind = "action",
            icon = "link",
            title = _("测试连接"),
            callback = function()
                testConnection(plugin)
            end,
        })
    end

    if caps.progress_push then
        rows[#rows + 1] = function(iw)
            return SettingRow.build(iw, {
                kind = "action",
                icon = "sync",
                title = _("立即同步进度"),
                callback = function()
                    local Progress = require("book.progress")
                    local src = plugin and plugin.getSource and plugin:getSource()
                    if not src then
                        return
                    end
                    NetworkMgr:runWhenOnline(function()
                        Progress.flushPendingAsync(src, true)
                    end)
                end,
            })
        end
    end

    if caps.stats_import then
        rows[#rows + 1] = function(iw)
            return SettingRow.build(iw, {
                kind = "action",
                icon = "bar_chart",
                title = _("立即上报统计"),
                callback = function()
                    local src = plugin and plugin.getSource and plugin:getSource()
                    StatsSync.pushWithUi(src, true, true)
                end,
            })
        end
    end

    return rows
end

--- 构建设置页（服务 / 显示 / 维护，分页）。
---@param desktop table
---@return table
function Settings.build(desktop)
    local h = desktop:contentHeight()
    local w = desktop.dimen.w
    local plugin = desktop.plugin
    local open_on = G_reader_settings:readSetting("start_with") == Host.OPEN_ON_START_ID
    local scale = UI.getScale()
    local font_name = MoonFont.currentName()
    local page_pad = UI.pagePad()
    local card_w = math.max(UI.sz(100), w - page_pad * 2)
    local band_h = Pager.bandH()
    local body_h = math.max(1, h - band_h)

    local sources = SourceRegistry.list()
    local active_id = MoonSettings.activeSourceId()
    local active_name = active_id
    for _, meta in ipairs(sources) do
        if meta.id == active_id then
            active_name = meta.name or meta.id
            break
        end
    end

    --- 弹出数据源选择 sheet。
    local function pickSource()
        if #sources == 0 then return end
        local items = {}
        for _, meta in ipairs(sources) do
            local id = meta.id
            local name = meta.name or meta.id
            local label = name
            if id == active_id then
                label = "✓ " .. name
            end
            table.insert(items, {
                text = label,
                value = id,
            })
        end
        Popup.sheet{
            title = _("选择数据源"),
            items = items,
            on_select = function(id)
                if not id or id == active_id then
                    return
                end
                SourceRegistry.setActive(id)
                if plugin and plugin.onSourceChanged then
                    plugin:onSourceChanged()
                end
                local name = id
                for _, meta in ipairs(sources) do
                    if meta.id == id then
                        name = meta.name or meta.id
                        break
                    end
                end
                UIManager:show(InfoMessage:new{
                    text = T(_("已切换数据源：%1"), name),
                    timeout = 2,
                })
                desktop:rebuild()
            end,
        }
    end

    local service_rows = {
        function(iw)
            return SettingRow.build(iw, {
                kind = "nav",
                icon = "source",
                title = _("数据源"),
                status = active_name,
                status_on = true,
                callback = pickSource,
            })
        end,
    }
    for _, build in ipairs(sourceServiceRows(active_id, plugin)) do
        table.insert(service_rows, build)
    end

    local packed = {}
    appendSection(packed, card_w, _("服务"), service_rows)
    appendSection(packed, card_w, _("显示"), {
        function(iw)
            return SettingRow.build(iw, {
                kind = "nav",
                icon = "text_fields",
                title = _("字体"),
                status = font_name,
                status_on = true,
                callback = function()
                    FontPicker.open{
                        title = _("字体"),
                        on_done = function()
                            desktop:rebuild()
                        end,
                    }
                end,
            })
        end,
        function(iw)
            return SettingRow.build(iw, {
                kind = "nav",
                icon = "format_size",
                title = _("字号"),
                status = string.format("%d%%", scale),
                status_on = true,
                callback = function()
                    Popup.spin{
                        title = _("字号"),
                        value = UI.getScale(),
                        value_min = UI.scaleMin(),
                        value_max = UI.scaleMax(),
                        value_step = UI.scaleStep(),
                        unit = "%",
                        ok_always_enabled = true,
                        callback = function(spin)
                            local n = UI.setScale(spin.value)
                            UIManager:show(InfoMessage:new{
                                text = string.format("%d%%", n),
                                timeout = 1.5,
                            })
                            desktop:rebuild()
                        end,
                    }
                end,
            })
        end,
        function(iw)
            return SettingRow.build(iw, {
                kind = "toggle",
                icon = "visibility",
                title = _("启动打开桌面"),
                status = open_on and _("开") or _("关"),
                status_on = open_on,
                callback = function()
                    if open_on then
                        G_reader_settings:saveSetting("start_with", "filemanager")
                    else
                        G_reader_settings:saveSetting("start_with", Host.OPEN_ON_START_ID)
                    end
                    desktop:rebuild()
                end,
            })
        end,
    })
    appendSection(packed, card_w, _("维护"), {
        function(iw)
            local cache_size = desktop._cache_size_label or _("计算中…")
            -- 扫完就置 label；只认 job 会让回调里的 rebuild 再次开扫，死循环
            if desktop._cache_size_label == nil and not desktop._cache_size_job then
                desktop._cache_size_job = Cache.sizeLabelAsync(function(label)
                    desktop._cache_size_job = nil
                    if desktop._closed then
                        return
                    end
                    desktop._cache_size_label = label
                    if desktop.tab == "settings" then
                        desktop:rebuild()
                    end
                end)
            end
            return SettingRow.build(iw, {
                kind = "action",
                icon = "delete",
                title = _("清理缓存"),
                status = cache_size,
                status_on = true,
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = T(_("删除 .moon/cache（%1）？"), cache_size),
                        ok_text = _("清理"),
                        ok_callback = function()
                            if desktop._cache_clear_job then
                                return
                            end
                            UIManager:show(InfoMessage:new{
                                text = _("正在清理缓存…"),
                                timeout = 1,
                            })
                            desktop._cache_clear_job = Cache.clearAsync(function(ok)
                                desktop._cache_clear_job = nil
                                if desktop._closed then
                                    return
                                end
                                if ok then
                                    desktop._cache_size_label = "0"
                                    desktop._home_state = nil
                                    desktop._home_loaded = false
                                    desktop._library_state = nil
                                    desktop:rebuild()
                                end
                                UIManager:show(InfoMessage:new{
                                    text = ok and _("已清理") or _("清理失败"),
                                    timeout = 2,
                                })
                            end)
                        end,
                    })
                end,
            })
        end,
        function(iw)
            return SettingRow.build(iw, {
                kind = "nav",
                icon = "info",
                title = _("关于"),
                status = pluginVersion(),
                status_on = true,
                callback = showAbout,
            })
        end,
        function(iw)
            return SettingRow.build(iw, {
                kind = "action",
                icon = "close",
                title = _("关闭桌面"),
                callback = function()
                    desktop:onClose()
                end,
            })
        end,
    })

    local pages_kids = Pager.pack(packed, body_h)
    local pages = #pages_kids
    local page = Pager.clamp(desktop._settings_page, pages)
    desktop._settings_page = page

    local page_body = FrameContainer:new{
        bordersize = 0,
        padding = page_pad,
        padding_bottom = UI.sz(4),
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = w, h = body_h },
        VerticalGroup:new(pages_kids[page]),
    }

    return (select(1, Pager.frame(w, h, {
        body = page_body,
        page = page,
        pages = pages,
        handlers = {
            on_prev = function()
                desktop._settings_page = page - 1
                desktop:rebuild()
            end,
            on_next = function()
                desktop._settings_page = page + 1
                desktop:rebuild()
            end,
            on_first = function()
                desktop._settings_page = 1
                desktop:rebuild()
            end,
            on_last = function()
                desktop._settings_page = pages
                desktop:rebuild()
            end,
        },
    })))
end

return Settings
