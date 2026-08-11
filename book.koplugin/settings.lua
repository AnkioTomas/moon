--[[--
设置页（桌面 Tab）
  分区卡片 + 图标行；明确「注入阅读页」开关

@module koplugin.book.settings
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
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local RightContainer = require("ui/widget/container/rightcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local UI = require("bookui")
local _ = require("gettext")
local T = require("ffi/util").template

local ScrollableContainer
do
    local ok, mod = pcall(require, "ui/widget/container/scrollablecontainer")
    if ok then ScrollableContainer = mod end
end

local Settings = {}

local SETTINGS_KEY = "book_plugin_v2"
local START_WITH_ID = "bookshelf_book"

local function settings()
    local s = G_reader_settings:readSetting(SETTINGS_KEY)
    if type(s) ~= "table" then
        s = {}
    end
    return s
end

local function save(s)
    G_reader_settings:saveSetting(SETTINGS_KEY, s)
end

local function pluginIconDir()
    local info = debug.getinfo(1, "S")
    local src = info and info.source
    if src and src:sub(1, 1) == "@" then
        local dir = src:sub(2):match("(.*/)")
        if dir then return dir .. "icons/" end
    end
    return "icons/"
end

local function loadIcon(name, size)
    size = size or UI.iconSz()
    local ok, img = pcall(function()
        return ImageWidget:new{
            file = pluginIconDir() .. name,
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
            background = Blitbuffer.gray(0.9),
            dimen = Geom:new{ w = line_w, h = 1 },
        },
    }
end

--- 设置行：图标 + 标题(+副标题) + 右侧状态/箭头
--- width 必须是最终占用宽度，内部几何一次性扣干净，禁止再溢出。
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
            fgcolor = Blitbuffer.gray(0.45),
        })
    end

    local right = HorizontalGroup:new{ align = "center" }
    if opts.status then
        table.insert(right, TextWidget:new{
            text = opts.status,
            face = UI.face("cfont", 15),
            max_width = status_w,
            fgcolor = opts.status_on and Blitbuffer.COLOR_BLACK or Blitbuffer.gray(0.45),
        })
    end
    if opts.chevron ~= false then
        if opts.status then
            table.insert(right, HorizontalSpan:new{ width = UI.sz(4) })
        end
        table.insert(right, TextWidget:new{
            text = "›",
            face = UI.face("cfont", 20),
            fgcolor = Blitbuffer.gray(0.4),
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

--- 分区：标题 + 行列表，无外框，靠留白区分
local function sectionBlock(width, title, row_builders)
    local kids = { align = "left" }
    table.insert(kids, LeftContainer:new{
        dimen = Geom:new{ w = width, h = UI.sz(32) },
        TextWidget:new{
            text = title,
            face = UI.face("cfont", 13),
            max_width = width,
            fgcolor = Blitbuffer.gray(0.4),
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
    local s = settings()
    local open_on = s.open_on_start ~= false
    local auto_sync = s.auto_sync ~= false
    local float_menu = s.reader_float_menu ~= false
    local header_mode = s.home_header or "clock"
    local scale = UI.getScale()
    local page_pad = UI.sz(16)
    local avail_w = math.max(UI.sz(120), w - page_pad * 2)
    -- ScrollableContainer 一旦出现竖条，会再扣 3*scroll_bar_width；
    -- 内容若仍按 avail_w 排，就会误开横向滚动条。内容先让出这条槽。
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
        local st = settings()
        st.reader_float_menu = not float_menu
        save(st)
        UIManager:show(InfoMessage:new{
            text = st.reader_float_menu ~= false
                and _("已开启：阅读页中部点击将打开 Book 菜单")
                or _("已关闭：阅读页恢复系统默认中部翻页"),
            timeout = 2,
        })
        desktop:rebuild()
    end

    local col = VerticalGroup:new{ align = "left" }
    table.insert(col, VerticalSpan:new{ width = UI.sz(8) })

    table.insert(col, sectionBlock(card_w, _("连接"), {
        function(iw)
            return settingRow(iw, {
                icon = "server.svg",
                title = _("服务器与令牌"),
                subtitle = _("服务地址、访问令牌、本地下载目录"),
                callback = function()
                    if plugin then plugin:showConfigDialog() end
                end,
            })
        end,
        function(iw)
            return settingRow(iw, {
                icon = "link.svg",
                title = _("测试连接"),
                subtitle = _("验证服务器与令牌是否可用"),
                callback = function()
                    if plugin then plugin:testConnection() end
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
                    local st = settings()
                    st.auto_sync = not auto_sync
                    save(st)
                    desktop:rebuild()
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
                    local st = settings()
                    if (st.home_header or "clock") == "hitokoto" then
                        st.home_header = "clock"
                    else
                        st.home_header = "hitokoto"
                    end
                    save(st)
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
                    local st = settings()
                    st.open_on_start = not open_on
                    save(st)
                    if st.open_on_start then
                        G_reader_settings:saveSetting("start_with", START_WITH_ID)
                    elseif G_reader_settings:readSetting("start_with") == START_WITH_ID then
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
                icon = "about.svg",
                title = _("关于"),
                subtitle = _("作者与项目地址"),
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = _([[Book 书库

作者：AnkioTomas
GitHub：https://github.com/AnkioTomas/moon]]),
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
    -- 强制上报宽度 = card_w，杜绝 FrameContainer 边框把 getSize().w 撑破
    local body = LeftContainer:new{
        dimen = Geom:new{ w = card_w, h = body_h },
        col_widget,
    }
    local scroll_h = h - page_pad * 2
    local content
    if ScrollableContainer and body_h > scroll_h then
        -- 视口用满 avail_w（右侧留给竖条）；内容只有 card_w → 不会再出横条
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
