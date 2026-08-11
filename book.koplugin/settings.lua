--[[--
设置页（桌面 Tab）
  分区 + 图标行；明确「注入阅读页」开关

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

local function sectionTitle(text, width)
    return LeftContainer:new{
        dimen = Geom:new{ w = width, h = UI.sz(32) },
        TextWidget:new{
            text = text,
            face = UI.face("cfont", 14),
            fgcolor = Blitbuffer.gray(0.4),
        },
    }
end

--- 设置行：图标 + 标题(+副标题) + 右侧状态/箭头
local function settingRow(width, opts)
    local icon_sz = UI.sz(22)
    local pad_x = UI.sz(12)
    local pad_y = UI.sz(10)
    local row_h = opts.subtitle and UI.sz(64) or UI.sz(52)
    local chev_w = UI.sz(20)
    local status_w = opts.status and UI.sz(72) or 0
    local text_w = math.max(UI.sz(40), width - pad_x * 2 - icon_sz - UI.sz(10) - status_w - chev_w)

    local title = TextWidget:new{
        text = opts.title,
        face = UI.face("cfont", 16),
        max_width = text_w,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local text_col = VerticalGroup:new{ align = "left", title }
    if opts.subtitle and opts.subtitle ~= "" then
        table.insert(text_col, VerticalSpan:new{ width = UI.sz(3) })
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
            face = UI.face("xx_smallinfofont", 14),
            fgcolor = opts.status_on and Blitbuffer.COLOR_BLACK or Blitbuffer.gray(0.45),
        })
        table.insert(right, HorizontalSpan:new{ width = UI.sz(4) })
    end
    if opts.chevron ~= false then
        table.insert(right, TextWidget:new{
            text = "›",
            face = UI.face("cfont", 20),
            fgcolor = Blitbuffer.gray(0.4),
        })
    end

    local inner = HorizontalGroup:new{
        align = "center",
        CenterContainer:new{
            dimen = Geom:new{ w = icon_sz + UI.sz(4), h = row_h - pad_y * 2 },
            loadIcon(opts.icon, icon_sz),
        },
        HorizontalSpan:new{ width = UI.sz(10) },
        LeftContainer:new{
            dimen = Geom:new{ w = text_w, h = row_h - pad_y * 2 },
            text_col,
        },
        RightContainer:new{
            dimen = Geom:new{ w = status_w + chev_w, h = row_h - pad_y * 2 },
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
    return tap, row_h
end

local function divider(width)
    return LineWidget:new{
        background = Blitbuffer.gray(0.85),
        dimen = Geom:new{ w = width, h = UI.line() },
    }
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
    local pad = UI.sz(12)
    local content_w = w - pad * 2

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

    -- —— 连接 ——
    table.insert(col, sectionTitle(_("连接"), content_w))
    local r1 = settingRow(content_w, {
        icon = "server.svg",
        title = _("服务器与令牌"),
        subtitle = _("Book 服务地址、访问令牌、本地下载目录"),
        callback = function()
            if plugin then plugin:showConfigDialog() end
        end,
    })
    table.insert(col, r1)
    table.insert(col, divider(content_w))
    local r2 = settingRow(content_w, {
        icon = "link.svg",
        title = _("测试连接"),
        subtitle = _("验证服务器与令牌是否可用"),
        callback = function()
            if plugin then plugin:testConnection() end
        end,
    })
    table.insert(col, r2)

    table.insert(col, VerticalSpan:new{ width = UI.sz(14) })

    -- —— 阅读 ——
    table.insert(col, sectionTitle(_("阅读"), content_w))
    local r3 = settingRow(content_w, {
        icon = "reader.svg",
        title = _("注入阅读页菜单"),
        subtitle = _("中部点击弹出 Book 悬浮面板（目录/字体/边距等）"),
        status = float_menu and _("开") or _("关"),
        status_on = float_menu,
        chevron = false,
        callback = on_toggle_float,
    })
    table.insert(col, r3)
    table.insert(col, divider(content_w))
    local r4 = settingRow(content_w, {
        icon = "sync.svg",
        title = _("自动同步进度"),
        subtitle = _("打开/关闭书籍与休眠时与服务器同步"),
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
    table.insert(col, r4)

    table.insert(col, VerticalSpan:new{ width = UI.sz(14) })

    -- —— 界面 ——
    table.insert(col, sectionTitle(_("界面"), content_w))
    local r5 = settingRow(content_w, {
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
    table.insert(col, r5)
    table.insert(col, divider(content_w))
    local r6 = settingRow(content_w, {
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
    table.insert(col, r6)
    table.insert(col, divider(content_w))
    local r7 = settingRow(content_w, {
        icon = "view.svg",
        title = _("启动时打开桌面"),
        subtitle = _("KOReader 启动后直接进入 Book 桌面"),
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
    table.insert(col, r7)

    table.insert(col, VerticalSpan:new{ width = UI.sz(14) })

    -- —— 其他 ——
    table.insert(col, sectionTitle(_("其他"), content_w))
    local r8 = settingRow(content_w, {
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
    table.insert(col, r8)
    table.insert(col, divider(content_w))
    local r9 = settingRow(content_w, {
        icon = "close.svg",
        title = _("关闭桌面"),
        subtitle = _("返回 KOReader 文件管理器"),
        callback = function()
            desktop:onClose()
        end,
    })
    table.insert(col, r9)
    table.insert(col, VerticalSpan:new{ width = UI.sz(20) })

    local body = VerticalGroup:new(col)
    local body_h = body:getSize().h
    local scroll_h = h - pad * 2
    local content
    if ScrollableContainer and body_h > scroll_h then
        content = ScrollableContainer:new{
            dimen = Geom:new{ w = content_w, h = scroll_h },
            show_parent = desktop,
            LeftContainer:new{
                dimen = Geom:new{ w = content_w, h = body_h },
                body,
            },
        }
    else
        content = body
    end

    return FrameContainer:new{
        bordersize = 0,
        padding = pad,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = w, h = h },
        LeftContainer:new{
            dimen = Geom:new{ w = content_w, h = math.min(body_h, scroll_h) },
            content,
        },
    }
end

return Settings
