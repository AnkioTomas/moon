--[[--
设置页（桌面 Tab）

@module koplugin.book.settings
--]]

local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local UI = require("bookui")
local _ = require("gettext")
local T = require("ffi/util").template

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

function Settings.build(desktop)
    local h = desktop:contentHeight()
    local w = desktop.dimen.w
    local plugin = desktop.plugin
    local s = settings()
    local open_on = s.open_on_start ~= false
    local auto_sync = s.auto_sync ~= false
    local header_mode = s.home_header or "clock"
    local scale = UI.getScale()

    local items = {
        {
            text = _("服务器与令牌"),
            callback = function()
                if plugin then plugin:showConfigDialog() end
            end,
        },
        {
            text = _("测试连接"),
            callback = function()
                if plugin then plugin:testConnection() end
            end,
        },
        {
            text = _("界面字号"),
            mandatory = string.format("%d%%", scale),
            callback = function()
                local n = UI.cycleScale()
                UIManager:show(InfoMessage:new{
                    text = T(_("字号已设为 %1%"), n),
                    timeout = 1.5,
                })
                desktop:rebuild()
            end,
        },
        {
            text = _("启动时打开桌面"),
            mandatory = open_on and _("开") or _("关"),
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
        },
        {
            text = _("自动同步进度"),
            mandatory = auto_sync and _("开") or _("关"),
            callback = function()
                local st = settings()
                st.auto_sync = not auto_sync
                save(st)
                desktop:rebuild()
            end,
        },
        {
            text = _("首页顶部"),
            mandatory = header_mode == "hitokoto" and _("每日一言") or _("时钟"),
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
        },
        {
            text = _("关闭桌面"),
            callback = function()
                desktop:onClose()
            end,
        },
    }

    local menu = Menu:new{
        -- 设置是底栏 Tab，不要标题栏关闭按钮；标题也多余
        no_title = true,
        item_table = items,
        width = w,
        height = h,
        items_font_size = UI.menuFontSize(),
        is_borderless = true,
        is_popout = false,
        covers_fullscreen = false,
        show_parent = desktop,
        close_callback = function() end,
    }
    -- 手势/返回不要关掉整个桌面（退出用「关闭桌面」项）
    menu.onClose = function() return true end
    menu.onCloseAllMenus = function() return true end
    menu.onMultiSwipe = function() return true end
    return menu
end

return Settings
