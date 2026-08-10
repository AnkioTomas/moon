--[[--
阅读页悬浮菜单：点屏幕中部弹出
  顶部书籍信息 · 目录 / 字体 / 主页（退出阅读回 Book 桌面）

@module koplugin.book.readermenu
--]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Event = require("ui/event")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local Menu = require("ui/widget/menu")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Cover = require("cover")
local UI = require("bookui")
local _ = require("gettext")
local Screen = Device.screen

--- 打开真正的字体列表（EPUB/CRE）；PDF 等退到顶部排版页，不再误开底部条
local function showFontSettings(ui)
    if not ui then
        return
    end
    local font = ui.font
    if font then
        if not font.face_table and font.setupFaceMenuTable then
            pcall(function() font:setupFaceMenuTable() end)
        end
        local items = font.face_table
        if type(items) == "table" then
            if items.needs_refresh and items.refresh_func then
                pcall(items.refresh_func)
                items = font.face_table
            end
            if type(items) == "table" and #items > 0 then
                UIManager:show(Menu:new{
                    title = _("字体"),
                    item_table = items,
                    is_borderless = true,
                    is_popout = false,
                    covers_fullscreen = true,
                    items_font_size = UI.menuFontSize(),
                    close_callback = function() end,
                })
                return
            end
        end
    end
    -- 无字体模块：打开顶部菜单「排版」页（通常是第 2 项）
    if ui.menu and ui.menu.onShowMenu then
        local idx = 2
        if ui.menu.tab_item_table == nil and ui.menu.setUpdateItemTable then
            pcall(function() ui.menu:setUpdateItemTable() end)
        end
        local tabs = ui.menu.tab_item_table
        if type(tabs) == "table" then
            for i, tab in ipairs(tabs) do
                if tab and (tab.id == "typeset" or tab.name == "typeset") then
                    idx = i
                    break
                end
            end
        end
        ui.menu:onShowMenu(idx)
        return
    end
    -- 最后兜底才是底部配置条（字号等）
    ui:handleEvent(Event:new("ShowConfigMenu"))
end

local ReaderFloatMenu = InputContainer:extend{
    name = "book_reader_float_menu",
    -- false：下层阅读页继续参与绘制，面板外仍能看到正文
    covers_fullscreen = false,
    plugin = nil,
}

local function docTitle(ui)
    local doc = ui and ui.document
    if not doc then
        return _("未知书籍")
    end
    local props = doc.getProps and doc:getProps() or {}
    if props.title and props.title ~= "" then
        return props.title
    end
    local file = doc.file or ""
    return file:match("([^/\\]+)$") or file or _("未知书籍")
end

local function docAuthor(ui)
    local doc = ui and ui.document
    if not doc or not doc.getProps then
        return ""
    end
    local props = doc:getProps() or {}
    local a = props.authors or props.author or ""
    if type(a) == "table" then
        a = table.concat(a, ", ")
    end
    return tostring(a)
end

function ReaderFloatMenu:init()
    self.dimen = Geom:new{
        x = 0, y = 0,
        w = Screen:getWidth(),
        h = Screen:getHeight(),
    }
    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back } },
        }
    end
    self:rebuild()
end

function ReaderFloatMenu:getSize()
    return self.dimen
end

function ReaderFloatMenu:onClose()
    self._closed = true
    local region = self._panel_dimen
    UIManager:close(self)
    -- 只刷面板区域，避免整屏闪；下层阅读页露出来
    if region then
        UIManager:setDirty("all", "ui", region)
    else
        UIManager:setDirty("all", "ui")
    end
    if self.close_callback then
        self.close_callback()
    end
    return true
end

function ReaderFloatMenu:onCloseWidget()
    self._closed = true
end

function ReaderFloatMenu:rebuild()
    local plugin = self.plugin
    local ui = plugin and plugin.ui
    local w = Screen:getWidth()
    local h = Screen:getHeight()
    local pad = UI.sz(16)
    local panel_w = math.min(w - pad * 2, UI.sz(420))
    local title = docTitle(ui)
    local author = docAuthor(ui)
    local pct = 0
    if plugin and plugin.currentFraction then
        pct = math.floor((plugin:currentFraction() or 0) * 100 + 0.5)
    end

    local filename = plugin and plugin.remoteFilenameForCurrent and plugin:remoteFilenameForCurrent()
    local cw, ch = UI.sz(72), UI.sz(100)
    local path = Cover.cachedPath(plugin, filename)
    local cover_w = Cover.widget(path, cw, ch, title)
    if not path and filename and plugin and plugin.getApi then
        Cover.ensureAsync(plugin:getApi(), plugin, filename, nil)
    end

    local info_w = math.max(UI.sz(40), panel_w - pad * 2 - cw - UI.sz(12))
    local info = VerticalGroup:new{
        align = "left",
        TextWidget:new{
            text = title,
            face = UI.face("cfont", 18),
            max_width = info_w,
            fgcolor = Blitbuffer.COLOR_BLACK,
        },
        VerticalSpan:new{ width = UI.sz(6) },
        TextWidget:new{
            text = author ~= "" and author or _("未知作者"),
            face = UI.face("xx_smallinfofont", 14),
            max_width = info_w,
            fgcolor = Blitbuffer.gray(0.45),
        },
        VerticalSpan:new{ width = UI.sz(10) },
        UI.progressBar(info_w, UI.sz(8), pct),
        VerticalSpan:new{ width = UI.sz(4) },
        TextWidget:new{
            text = string.format("%d%%", pct),
            face = UI.face("xx_smallinfofont", 13),
            fgcolor = Blitbuffer.gray(0.4),
        },
    }

    local header = HorizontalGroup:new{
        align = "top",
        cover_w,
        HorizontalSpan:new{ width = UI.sz(12) },
        LeftContainer:new{
            dimen = Geom:new{ w = info_w, h = math.max(ch, UI.sz(100)) },
            info,
        },
    }

    local btn_font = UI.buttonFontSize()
    local function afterClose(fn)
        return function()
            self:onClose()
            UIManager:nextTick(fn)
        end
    end

    local buttons = ButtonTable:new{
        width = panel_w - pad * 2,
        buttons = {
            {
                {
                    text = _("目录"),
                    font_size = btn_font,
                    callback = afterClose(function()
                        if ui and ui.toc and ui.toc.onShowToc then
                            ui.toc:onShowToc()
                        end
                    end),
                },
                {
                    text = _("字体"),
                    font_size = btn_font,
                    callback = afterClose(function()
                        showFontSettings(ui)
                    end),
                },
            },
            {
                {
                    text = _("主页"),
                    font_size = btn_font,
                    callback = afterClose(function()
                        if plugin and plugin.exitReadingToDesktop then
                            plugin:exitReadingToDesktop()
                        end
                    end),
                },
                {
                    text = _("关闭"),
                    font_size = btn_font,
                    callback = function()
                        self:onClose()
                    end,
                },
            },
        },
        zero_sep = true,
        show_parent = self,
    }

    local body = VerticalGroup:new{
        align = "center",
        header,
        VerticalSpan:new{ width = UI.sz(14) },
        LineWidget:new{
            background = Blitbuffer.gray(0.8),
            dimen = Geom:new{ w = panel_w - pad * 2, h = UI.line() },
        },
        VerticalSpan:new{ width = UI.sz(14) },
        buttons,
    }
    local body_h = body:getSize().h
    local panel_h = body_h + pad * 2
    local panel_x = math.floor((w - panel_w) / 2)
    local panel_y = math.floor((h - panel_h) / 2)
    self._panel_dimen = Geom:new{
        x = panel_x,
        y = panel_y,
        w = panel_w,
        h = panel_h,
    }

    local panel = FrameContainer:new{
        bordersize = math.max(2, UI.line()),
        color = Blitbuffer.COLOR_BLACK,
        padding = pad,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = panel_w, h = panel_h },
        body,
    }

    -- 只画居中面板，不铺全屏白底；阅读页在四周保持可见
    self[1] = CenterContainer:new{
        dimen = Geom:new{ w = w, h = h },
        panel,
    }
    self.dimen = Geom:new{ x = 0, y = 0, w = w, h = h }
end

return ReaderFloatMenu
