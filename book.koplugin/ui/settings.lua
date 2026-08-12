--[[--
设置页 UI（桌面 Tab）
  只负责渲染与交互；读写一律走 moon.settings

@module koplugin.book.ui.settings
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local RightContainer = require("ui/widget/container/rightcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local UI = require("ui.components.bookui")
local MoonSettings = require("moon.settings")
local SourceRegistry = require("source.registry")
local Cache = require("moon.cache")
local Host = require("moon.host")
local _ = require("gettext")
local T = require("ffi/util").template

local function pluginVersion()
    local ok, ver = pcall(require, "bookversion")
    if ok and type(ver) == "string" and ver ~= "" then
        return ver
    end
    return "0.0.0-dev"
end

local ScrollableContainer
do
    local ok, mod = pcall(require, "ui/widget/container/scrollablecontainer")
    if ok then ScrollableContainer = mod end
end

local Settings = {}

local function showServerDialog(plugin)
    local moon = MoonSettings.getSource("moon")
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Book 服务器配置"),
        fields = {
            { text = moon.base_url or "", hint = _("https://book.example.com") },
            { text = moon.token or "", hint = _("bk_… 长期令牌"), text_type = "password" },
        },
        buttons = {{
            {
                text = _("取消"),
                id = "close",
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("保存"),
                callback = function()
                    local fields = dialog:getFields()
                    moon.base_url = (fields[1] or ""):gsub("%s+", "")
                    moon.token = (fields[2] or ""):gsub("%s+", "")
                    MoonSettings.saveSource("moon", moon)
                    SourceRegistry.invalidate()
                    UIManager:close(dialog)
                    UIManager:show(InfoMessage:new{ text = _("已保存"), timeout = 2 })
                    if plugin and plugin.onSourceChanged then
                        plugin:onSourceChanged()
                    end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local function testConnection(plugin)
    if not plugin or not plugin.getSource then
        return
    end
    NetworkMgr:runWhenOnline(function()
        local res, err = plugin:getSource():ping()
        if not res then
            UIManager:show(InfoMessage:new{ text = err or _("连接失败") })
            return
        end
        local name = res.data and (res.data.display_name or res.data.username) or "?"
        UIManager:show(InfoMessage:new{
            text = T(_("连接成功：%1"), name),
            timeout = 3,
        })
    end)
end


local function loadIcon(name, size)
    size = size or UI.iconSz()
    local ok, img = pcall(function()
        return ImageWidget:new{
            file = UI.iconDir() .. name,
            width = size,
            height = size,
            alpha = true,
        }
    end)
    if ok and img then
        return img
    end
    return TextWidget:new{
        text = "·",
        face = UI.face("cfont", 16),
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
end

local function tappable(w, h, on_tap)
    local tap = InputContainer:new{
        dimen = Geom:new{ w = w, h = h },
    }
    tap.ges_events = {
        TapSettings = {
            GestureRange:new{
                ges = "tap",
                range = function() return tap.dimen end,
            },
        },
    }
    tap.onTapSettings = function()
        if on_tap then on_tap() end
        return true
    end
    return tap
end

local function insetDivider(width)
    local inset = UI.sz(16)
    local line_w = math.max(UI.sz(40), width - inset * 2)
    return CenterContainer:new{
        dimen = Geom:new{ w = width, h = UI.sz(1) },
        LineWidget:new{
            background = UI.rule(),
            dimen = Geom:new{ w = line_w, h = 1 },
        },
    }
end

--- 设置行：图标 + 标题(+副标题) + 右侧状态/箭头
local function settingRow(width, opts)
    local icon_sz = UI.sz(24)
    local pad_x = UI.sz(8)
    local pad_y = UI.sz(16)
    local row_h = opts.subtitle and UI.sz(78) or UI.sz(62)
    local icon_col = icon_sz + UI.sz(6)
    local icon_gap = UI.sz(12)
    local chev_w = opts.chevron == false and 0 or UI.sz(18)
    local status_w = opts.status and UI.sz(56) or 0
    local inner_w = math.max(1, width - pad_x * 2)
    local text_w = math.max(UI.sz(40), inner_w - icon_col - icon_gap - status_w - chev_w)

    local title = TextWidget:new{
        text = opts.title,
        face = UI.face("cfont", 16),
        max_width = text_w,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local text_col = VerticalGroup:new{ align = "left", title }
    if opts.subtitle and opts.subtitle ~= "" then
        table.insert(text_col, VerticalSpan:new{ width = UI.sz(6) })
        table.insert(text_col, TextWidget:new{
            text = opts.subtitle,
            face = UI.face("xx_smallinfofont", 12),
            max_width = text_w,
            fgcolor = UI.muted(),
        })
    end

    local right = HorizontalGroup:new{ align = "center" }
    if opts.status then
        table.insert(right, TextWidget:new{
            text = opts.status,
            face = UI.face("cfont", 15),
            max_width = status_w,
            fgcolor = opts.status_on and Blitbuffer.COLOR_BLACK or UI.muted(),
        })
    end
    if opts.chevron ~= false then
        if opts.status then
            table.insert(right, HorizontalSpan:new{ width = UI.sz(4) })
        end
        table.insert(right, TextWidget:new{
            text = "›",
            face = UI.face("cfont", 20),
            fgcolor = UI.muted(),
        })
    end

    local right_w = status_w + chev_w
    local inner = HorizontalGroup:new{
        align = "center",
        CenterContainer:new{
            dimen = Geom:new{ w = icon_col, h = row_h - pad_y * 2 },
            loadIcon(opts.icon, icon_sz),
        },
        HorizontalSpan:new{ width = icon_gap },
        LeftContainer:new{
            dimen = Geom:new{ w = text_w, h = row_h - pad_y * 2 },
            text_col,
        },
        RightContainer:new{
            dimen = Geom:new{ w = right_w, h = row_h - pad_y * 2 },
            right,
        },
    }

    local tap = tappable(width, row_h, opts.callback)
    tap[1] = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        padding_left = pad_x,
        padding_right = pad_x,
        padding_top = pad_y,
        padding_bottom = pad_y,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = width, h = row_h },
        inner,
    }
    return tap
end

local function sectionBlock(width, title, row_builders)
    local kids = { align = "left" }
    table.insert(kids, LeftContainer:new{
        dimen = Geom:new{ w = width, h = UI.sz(32) },
        TextWidget:new{
            text = title,
            face = UI.face("cfont", 13),
            max_width = width,
            fgcolor = UI.muted(),
        },
    })
    table.insert(kids, VerticalSpan:new{ width = UI.sz(4) })
    for i, build in ipairs(row_builders) do
        if i > 1 then
            table.insert(kids, insetDivider(width))
        end
        table.insert(kids, build(width))
    end
    return VerticalGroup:new(kids)
end

function Settings.build(desktop)
    local h = desktop:contentHeight()
    local w = desktop.dimen.w
    local plugin = desktop.plugin
    local s = MoonSettings.get()
    local open_on = s.open_on_start ~= false
    local auto_sync = s.auto_sync ~= false
    local auto_stats = s.auto_stats ~= false
    local float_menu = s.reader_float_menu ~= false
    local header_mode = s.home_header or "clock"
    local scale = UI.getScale()
    local page_pad = UI.sz(16)
    local avail_w = math.max(UI.sz(120), w - page_pad * 2)
    local sb_gutter = 0
    if ScrollableContainer then
        if ScrollableContainer.getScrollbarWidth then
            sb_gutter = ScrollableContainer:getScrollbarWidth()
        else
            local Device = require("device")
            sb_gutter = 3 * Device.screen:scaleBySize(6)
        end
    end
    local card_w = math.max(UI.sz(100), avail_w - sb_gutter)
    local section_gap = UI.sz(28)

    local function on_toggle_float()
        local st = MoonSettings.get()
        st.reader_float_menu = not float_menu
        MoonSettings.save(st)
        UIManager:show(InfoMessage:new{
            text = st.reader_float_menu ~= false
                and _("已开启：阅读页中部点击将打开 Book 菜单")
                or _("已关闭：阅读页恢复系统默认中部翻页"),
            timeout = 2,
        })
        desktop:rebuild()
    end

    local sources = SourceRegistry.list()
    local active_id = MoonSettings.activeSourceId()
    local active_name = active_id
    for _, meta in ipairs(sources) do
        if meta.id == active_id then
            active_name = meta.name or meta.id
            break
        end
    end

    local function cycleSource()
        if #sources == 0 then return end
        local idx = 1
        for i, meta in ipairs(sources) do
            if meta.id == active_id then
                idx = i
                break
            end
        end
        local next_meta = sources[(idx % #sources) + 1]
        SourceRegistry.setActive(next_meta.id)
        if plugin and plugin.onSourceChanged then
            plugin:onSourceChanged()
        end
        UIManager:show(InfoMessage:new{
            text = T(_("已切换数据源：%1"), next_meta.name or next_meta.id),
            timeout = 2,
        })
    end

    local col = VerticalGroup:new{ align = "left" }
    table.insert(col, VerticalSpan:new{ width = UI.sz(8) })

    table.insert(col, sectionBlock(card_w, _("数据源"), {
        function(iw)
            return settingRow(iw, {
                icon = "view.svg",
                title = _("当前数据源"),
                subtitle = _("点按切换；同时仅激活一个源"),
                status = active_name,
                status_on = true,
                callback = cycleSource,
            })
        end,
    }))
    table.insert(col, VerticalSpan:new{ width = section_gap })

    table.insert(col, sectionBlock(card_w, _("连接"), {
        function(iw)
            return settingRow(iw, {
                icon = "server.svg",
                title = _("服务器与令牌"),
                subtitle = _("Book 服务地址与访问令牌"),
                callback = function()
                    showServerDialog(plugin)
                end,
            })
        end,
        function(iw)
            return settingRow(iw, {
                icon = "link.svg",
                title = _("测试连接"),
                subtitle = _("验证当前数据源是否可用"),
                callback = function()
                    testConnection(plugin)
                end,
            })
        end,
    }))
    table.insert(col, VerticalSpan:new{ width = section_gap })

    table.insert(col, sectionBlock(card_w, _("阅读"), {
        function(iw)
            return settingRow(iw, {
                icon = "reader.svg",
                title = _("注入阅读页菜单"),
                subtitle = _("中部点击弹出 Book 悬浮面板"),
                status = float_menu and _("开") or _("关"),
                status_on = float_menu,
                chevron = false,
                callback = on_toggle_float,
            })
        end,
        function(iw)
            return settingRow(iw, {
                icon = "sync.svg",
                title = _("自动同步进度"),
                subtitle = _("打开、关闭与休眠时同步进度"),
                status = auto_sync and _("开") or _("关"),
                status_on = auto_sync,
                chevron = false,
                callback = function()
                    local st = MoonSettings.get()
                    st.auto_sync = not auto_sync
                    MoonSettings.save(st)
                    desktop:rebuild()
                end,
            })
        end,
        function(iw)
            return settingRow(iw, {
                icon = "sync.svg",
                title = _("自动上报阅读统计"),
                subtitle = _("依赖 KOReader 阅读统计；关闭/休眠时上传"),
                status = auto_stats and _("开") or _("关"),
                status_on = auto_stats,
                chevron = false,
                callback = function()
                    local st = MoonSettings.get()
                    st.auto_stats = not auto_stats
                    MoonSettings.save(st)
                    desktop:rebuild()
                end,
            })
        end,
        function(iw)
            return settingRow(iw, {
                icon = "sync.svg",
                title = _("立即上报阅读统计"),
                subtitle = _("后台上传；显示进度条"),
                callback = function()
                    if plugin then
                        plugin:pushReadingStats(true, true)
                    end
                end,
            })
        end,
    }))
    table.insert(col, VerticalSpan:new{ width = section_gap })

    table.insert(col, sectionBlock(card_w, _("界面"), {
        function(iw)
            return settingRow(iw, {
                icon = "font_size.svg",
                title = _("界面字号"),
                subtitle = _("桌面与悬浮面板统一缩放"),
                status = string.format("%d%%", scale),
                status_on = true,
                chevron = false,
                callback = function()
                    local n = UI.cycleScale()
                    UIManager:show(InfoMessage:new{
                        text = T(_("字号已设为 %1%"), n),
                        timeout = 1.5,
                    })
                    desktop:rebuild()
                end,
            })
        end,
        function(iw)
            return settingRow(iw, {
                icon = "home.svg",
                title = _("首页顶部"),
                subtitle = _("时钟或每日一言"),
                status = header_mode == "hitokoto" and _("一言") or _("时钟"),
                status_on = true,
                chevron = false,
                callback = function()
                    local st = MoonSettings.get()
                    if (st.home_header or "clock") == "hitokoto" then
                        st.home_header = "clock"
                    else
                        st.home_header = "hitokoto"
                    end
                    MoonSettings.save(st)
                    desktop._home_state = nil
                    desktop._home_loaded = false
                    desktop:rebuild()
                end,
            })
        end,
        function(iw)
            return settingRow(iw, {
                icon = "view.svg",
                title = _("启动时打开桌面"),
                subtitle = _("启动后直接进入 Book 桌面"),
                status = open_on and _("开") or _("关"),
                status_on = open_on,
                chevron = false,
                callback = function()
                    local st = MoonSettings.get()
                    st.open_on_start = not open_on
                    MoonSettings.save(st)
                    if st.open_on_start then
                        G_reader_settings:saveSetting("start_with", Host.OPEN_ON_START_ID)
                    elseif G_reader_settings:readSetting("start_with") == Host.OPEN_ON_START_ID then
                        G_reader_settings:saveSetting("start_with", "filemanager")
                    end
                    desktop:rebuild()
                end,
            })
        end,
    }))
    table.insert(col, VerticalSpan:new{ width = section_gap })

    table.insert(col, sectionBlock(card_w, _("其他"), {
        function(iw)
            return settingRow(iw, {
                icon = "trash.svg",
                title = _("清理缓存"),
                subtitle = _("删除本地下载的书籍与封面"),
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = _("将删除 .moon/cache 下的书籍与封面，不影响服务器数据。确定清理？"),
                        ok_text = _("清理"),
                        ok_callback = function()
                            local books, covers = Cache.clear()
                            if desktop then
                                desktop._home_state = nil
                                desktop._home_loaded = false
                                desktop._library_state = nil
                                desktop:rebuild()
                            end
                            UIManager:show(InfoMessage:new{
                                text = T(_("已清理：书籍 %1，封面 %2"), books, covers),
                                timeout = 2.5,
                            })
                        end,
                    })
                end,
            })
        end,
        function(iw)
            local ver = pluginVersion()
            return settingRow(iw, {
                icon = "about.svg",
                title = _("关于"),
                subtitle = T(_("版本 %1"), ver),
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = T(_([[Book 书库
版本：%1

作者：AnkioTomas
GitHub：https://github.com/AnkioTomas/moon]]), ver),
                    })
                end,
            })
        end,
        function(iw)
            return settingRow(iw, {
                icon = "close.svg",
                title = _("关闭桌面"),
                subtitle = _("返回 KOReader 文件管理器"),
                callback = function()
                    desktop:onClose()
                end,
            })
        end,
    }))
    table.insert(col, VerticalSpan:new{ width = UI.sz(28) })

    local col_widget = VerticalGroup:new(col)
    local body_h = col_widget:getSize().h
    local body = LeftContainer:new{
        dimen = Geom:new{ w = card_w, h = body_h },
        col_widget,
    }
    local scroll_h = h - page_pad * 2
    local content
    if ScrollableContainer and body_h > scroll_h then
        content = ScrollableContainer:new{
            dimen = Geom:new{ w = avail_w, h = scroll_h },
            show_parent = desktop,
            body,
        }
        desktop.cropping_widget = content
    else
        desktop.cropping_widget = nil
        content = body
    end

    return FrameContainer:new{
        bordersize = 0,
        padding = page_pad,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = w, h = h },
        LeftContainer:new{
            dimen = Geom:new{ w = avail_w, h = math.min(body_h, scroll_h) },
            content,
        },
    }
end

return Settings
