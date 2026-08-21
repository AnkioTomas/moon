--[[--
阅读控制台：顶部的阅读风格、字体、阅读设置，和底部的目录、书签、注解。

这里不重写 KOReader 的目录、书签、注解或排版状态，只提供固定、轻量的
Kindle 风格入口。弹出原生窗口前关闭控制台，避免全屏层叠和输入遮挡。

@module koplugin.book.ui.reader.panel
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Event = require("ui/event")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local TopContainer = require("ui/widget/container/topcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local Icon = require("ui.components.icon")
local Popup = require("ui.components.popup")
local UI = require("ui.components.bookui")
local Session = require("ui.reader.session")
local Settings = require("utils.settings")
local _ = require("gettext")
local Screen = Device.screen

local Panel = InputContainer:extend{
    name = "book_reader_toolbar",
    covers_fullscreen = false,
    plugin = nil,
}

---@param width number
---@param height number
---@param icon string
---@param label string
---@param callback fun()
---@param active boolean|nil
---@return table
local function action(width, height, icon, label, callback, active)
    local tap = InputContainer:new{ dimen = Geom:new{ w = width, h = height } }
    tap.ges_events = {
        TapBookReaderAction = {
            GestureRange:new{ ges = "tap", range = function() return tap:getSize() end },
        },
    }
    tap.onTapBookReaderAction = function()
        callback()
        return true
    end
    local color = Blitbuffer.COLOR_BLACK
    tap[1] = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        width = width,
        height = height,
        CenterContainer:new{
            dimen = Geom:new{ w = width, h = height },
            Icon.label{
                name = icon,
                text = label,
                direction = "column",
                color = color,
                face = active and "cfont" or "xx_smallinfofont",
                font_size = active and 12 or 11,
                max_width = math.max(UI.sz(36), width - UI.sz(6)),
                gap = UI.sz(2),
            },
        },
    }
    return tap
end

---@param ui table|nil
---@return boolean
local function isReflowable(ui)
    return ui and ui.rolling and ui.font and ui.font.onSetFont and ui.font.onSetFontSize
end

---@param panel table
local function showReaderSettings(panel)
    panel:onClose()
    local common = Settings.get()
    local ui = panel.plugin and panel.plugin.ui
    Popup.list{
        title = _("阅读设置"),
        select_mode = "multi",
        items = {
            { text = _("顶部时间"), value = "top_time", checked = common.book_reader_show_top_time ~= false },
            { text = _("底部进度"), value = "bottom_progress", checked = common.book_reader_show_bottom_progress ~= false },
            {
                text = _("翻页动画"), value = "page_animation",
                checked = G_reader_settings:isTrue("swipe_animations"),
                enabled = ui ~= nil and ui.view ~= nil
                    and ui.view.onTogglePageChangeAnimation ~= nil,
            },
            {
                text = _("OCR 语言数据"),
                mandatory_func = function() return require("ui.reader.ocr").status() end,
                sub_item_table = {
                    {
                        text = _("安装或选择 OCR 语言"),
                        callback = function() require("ui.reader.ocr").open(ui) end,
                    },
                },
            },
        },
        on_toggle = function(value, checked)
            local settings = Settings.get()
            if value == "top_time" then
                settings.book_reader_show_top_time = checked
                Settings.save(settings)
            elseif value == "bottom_progress" then
                settings.book_reader_show_bottom_progress = checked
                Settings.save(settings)
            elseif value == "page_animation" and ui and ui.view then
                ui.view:onTogglePageChangeAnimation()
            end
            require("ui.reader").refresh(panel.plugin)
        end,
    }
end

---@param ui table
local function showFontFaces(ui)
    local ok, cre = pcall(function()
        return require("document/credocument"):engineInit()
    end)
    if not ok or not cre then
        return
    end
    local items = {}
    for _, face in ipairs(cre.getFontFaces() or {}) do
        items[#items + 1] = { text = face, value = face }
    end
    Popup.list{
        title = _("阅读字体"),
        items = items,
        current = ui.font.font_face,
        choice_icons = true,
        on_select = function(face)
            ui.font:onSetFont(face)
        end,
    }
end

---@param panel table
local function showTypography(panel)
    panel:onClose()
    local ui = panel.plugin and panel.plugin.ui
    if not isReflowable(ui) then
        UIManager:show(require("ui/widget/infomessage"):new{
            text = _("当前文档不支持字体与排版调整"),
        })
        return
    end
    local font = ui.font
    local config = font.configurable
    local function spin(title, value, min, max, step, unit, callback)
        Popup.spin{
            title = title,
            value = value,
            value_min = min,
            value_max = max,
            value_step = step,
            unit = unit,
            ok_always_enabled = true,
            callback = function(widget)
                callback(widget.value)
            end,
        }
    end
    Popup.list{
        title = _("阅读字体"),
        items = {
            {
                text = _("字体"), mandatory = font.font_face,
                callback = function() showFontFaces(ui) end,
            },
            {
                text = _("字号"), mandatory = string.format("%.1f", tonumber(config.font_size) or 0),
                callback = function()
                    spin(_("字号"), config.font_size, 12, 255, 0.5, "pt", function(value)
                        font:onSetFontSize(value)
                    end)
                end,
            },
            {
                text = _("行距"), mandatory = string.format("%d%%", tonumber(config.line_spacing) or 100),
                callback = function()
                    spin(_("行距"), config.line_spacing, 50, 200, 1, "%", function(value)
                        font:onSetLineSpace(value)
                    end)
                end,
            },
            {
                text = _("字重"), mandatory = string.format("%+.2f", tonumber(config.font_base_weight) or 0),
                callback = function()
                    spin(_("字重"), config.font_base_weight, -3, 5.5, 0.25, nil, function(value)
                        font:onSetFontBaseWeight(value)
                    end)
                end,
            },
            {
                text = _("字间扩展"), mandatory = string.format("%d%%", tonumber(config.word_expansion) or 0),
                callback = function()
                    spin(_("字间扩展"), config.word_expansion, 0, 20, 1, "%", function(value)
                        font:onSetWordExpansion(value)
                    end)
                end,
            },
        },
    }
end

---@param panel table
local function showToc(panel)
    local ui = panel.plugin and panel.plugin.ui
    panel:onClose()
    local session = require("ui.reader.session")
    local toc = session.toc()
    if toc then
        local current = session.current()
        local identity = current and current.identity
        local current_idx = identity and identity.chapter_idx
        local items = {}
        for _, chapter in ipairs(toc) do
            local idx = tonumber(chapter.idx) or 0
            items[#items + 1] = {
                text = chapter.title or ("#" .. idx),
                value = idx,
                checked = idx == current_idx,
            }
        end
        Popup.list{
            title = _("目录"), items = items, choice_icons = true,
            on_select = function(idx) session.gotoChapter(idx) end,
        }
    elseif ui and ui.toc and ui.toc.onShowToc then
        ui.toc:onShowToc()
    end
end

function Panel:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self:rebuild()
    self:registerTouchZones({
        {
            id = "book_reader_toolbar_close",
            ges = "tap",
            screen_zone = { ratio_x = 0, ratio_y = 0.16, ratio_w = 1, ratio_h = 0.68 },
            handler = function()
                self:onClose()
                return true
            end,
        },
    })
end

---@return table
function Panel:getSize()
    return self.dimen
end

function Panel:onClose()
    if self._closed then
        return true
    end
    self._closed = true
    UIManager:close(self)
    local callback = self.close_callback
    self.close_callback = nil
    if callback then
        callback()
    end
    return true
end

function Panel:onCloseWidget()
    self._closed = true
    local callback = self.close_callback
    self.close_callback = nil
    if callback then
        callback()
    end
end

function Panel:rebuild()
    local w, h = Screen:getWidth(), Screen:getHeight()
    local top_h = UI.barH()
    local bottom_h = UI.barH()
    local current = Session.current() or {}
    local identity = current.identity
    local toc = Session.toc()
    local ui = self.plugin and self.plugin.ui
    local title = (identity and identity.book and identity.book.title) or _("阅读")
    if identity and identity.chapter_idx and toc then
        title = string.format(_("第 %d/%d 章"), identity.chapter_idx, #toc)
    end
    local title_w = math.floor(w * 0.42)
    local action_w = math.floor((w - title_w) / 3)
    local top = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        width = w,
        height = top_h,
        HorizontalGroup:new{
            align = "center",
            LeftContainer:new{
                dimen = Geom:new{ w = title_w, h = top_h },
                TextWidget:new{
                    text = title,
                    face = UI.face("cfont", 15),
                    fgcolor = Blitbuffer.COLOR_BLACK,
                    max_width = title_w - UI.sz(12),
                },
            },
            action(action_w, top_h, "format_paint", _("阅读风格"), function()
                self:onClose()
                if ui then ui:handleEvent(Event:new("ShowConfigMenu")) end
            end),
            action(action_w, top_h, "text_fields", _("阅读字体"), function()
                showTypography(self)
            end),
            action(action_w, top_h, "settings", _("阅读设置"), function()
                showReaderSettings(self)
            end),
        },
    }
    local bottom_w = math.floor(w / 3)
    local bookmarked = ui and ui.bookmark and ui.bookmark.isPageBookmarked
        and ui.bookmark:isPageBookmarked() or false
    local bottom = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        width = w,
        height = bottom_h,
        HorizontalGroup:new{
            action(bottom_w, bottom_h, "toc", _("目录"), function()
                showToc(self)
            end),
            action(bottom_w, bottom_h, bookmarked and "bookmark" or "bookmark_border", _("书签"), function()
                if ui and ui.bookmark and ui.bookmark.onToggleBookmark then
                    ui.bookmark:onToggleBookmark()
                    self:rebuild()
                    UIManager:setDirty(self, "ui")
                end
            end, bookmarked),
            action(w - bottom_w * 2, bottom_h, "format_quote", _("书签与高亮"), function()
                self:onClose()
                if ui and ui.bookmark and ui.bookmark.onShowBookmark then
                    ui.bookmark:onShowBookmark()
                end
            end),
        },
    }
    self[1] = OverlapGroup:new{
        dimen = self.dimen,
        TopContainer:new{
            dimen = Geom:new{ w = w, h = h },
            top,
        },
        BottomContainer:new{
            dimen = Geom:new{ w = w, h = h },
            bottom,
        },
    }
end

return Panel
