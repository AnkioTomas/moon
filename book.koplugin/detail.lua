--[[--
书籍详情：顶栏 + 可滚动内容 + 底部固定按钮
（长简介时按钮仍可点）

@module koplugin.book.detail
--]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Cover = require("cover")
local UI = require("bookui")
local _ = require("gettext")
local Screen = Device.screen

local ScrollableContainer
do
    local ok, mod = pcall(require, "ui/widget/container/scrollablecontainer")
    if ok then ScrollableContainer = mod end
end

local Detail = InputContainer:extend{
    name = "book_detail",
    covers_fullscreen = true,
    book = nil,
    plugin = nil,
    api = nil,
    desktop = nil,
}

local function bookPct(book)
    local p = book and book.progressPercent
    if type(p) == "string" then
        p = p:gsub("%%", ""):match("[%d%.]+")
    end
    p = tonumber(p) or 0
    if p < 0 then p = 0 end
    if p > 100 then p = 100 end
    return p
end

local function metaRow(label, value, width)
    if not value or value == "" then
        return nil
    end
    local label_w = UI.sz(72)
    local value_w = math.max(UI.sz(40), width - label_w - UI.sz(8))
    return HorizontalGroup:new{
        LeftContainer:new{
            dimen = Geom:new{ w = label_w, h = UI.sz(28) },
            TextWidget:new{
                text = label,
                face = UI.face("xx_smallinfofont", 14),
                fgcolor = Blitbuffer.gray(0.45),
            },
        },
        TextWidget:new{
            text = tostring(value),
            face = UI.face("cfont", 15),
            max_width = value_w,
            fgcolor = Blitbuffer.COLOR_BLACK,
        },
    }
end

local function sectionTitle(text, width)
    return LeftContainer:new{
        dimen = Geom:new{ w = width, h = UI.sz(30) },
        TextWidget:new{
            text = text,
            face = UI.face("cfont", 15),
            fgcolor = Blitbuffer.COLOR_BLACK,
        },
    }
end

function Detail:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back } },
        }
    end
    self:rebuild()
end

function Detail:getSize()
    return self.dimen
end

function Detail:onClose()
    self._closed = true
    UIManager:close(self)
    if self.close_callback then
        self.close_callback()
    end
    return true
end

function Detail:onCloseWidget()
    self._closed = true
end

function Detail:rebuild()
    local book = self.book or {}
    local w = Screen:getWidth()
    local h = Screen:getHeight()
    local pad = UI.sz(16)
    local content_w = w - pad * 2
    local title = book.bookName or book.filename or book.fileName or _("书籍详情")
    local filename = book.filename or book.fileName or book.file or book.path
    local pct = bookPct(book)

    local cw = UI.sz(120)
    local ch = UI.sz(170)
    local path = Cover.cachedPath(self.plugin, filename)
    local cover_w = Cover.widget(path, cw, ch, title)
    if not path and filename then
        Cover.ensureAsync(self.api, self.plugin, filename, nil)
    end

    local title_bar = TitleBar:new{
        fullscreen = true,
        width = w,
        align = "center",
        with_bottom_line = true,
        title = title,
        title_face = UI.face("cfont", 18),
        close_callback = function()
            self:onClose()
        end,
        show_parent = self,
    }

    local buttons = ButtonTable:new{
        width = content_w,
        buttons = {{
            {
                text = _("返回"),
                callback = function()
                    self:onClose()
                end,
            },
            {
                text = _("开始阅读"),
                callback = function()
                    local plugin = self.plugin
                    local b = self.book
                    self:onClose()
                    if plugin and plugin.openBook then
                        plugin:openBook(b)
                    end
                end,
            },
        }},
        zero_sep = true,
        show_parent = self,
    }

    local button_h = buttons:getSize().h
    local title_h = title_bar:getHeight()
    local footer_h = button_h + pad * 2 + Size.line.medium + UI.sz(8)
    local scroll_h = math.max(UI.sz(80), h - title_h - footer_h)

    local meta_w = math.max(UI.sz(80), content_w - cw - UI.sz(14))
    local meta_kids = {
        align = "left",
        TextBoxWidget:new{
            text = title,
            face = UI.face("cfont", 18),
            width = meta_w,
            alignment = "left",
            fgcolor = Blitbuffer.COLOR_BLACK,
        },
        VerticalSpan:new{ width = UI.sz(10) },
    }
    local rows = {
        metaRow(_("作者"), book.author, meta_w),
        metaRow(_("分类"), book.category, meta_w),
        metaRow(_("系列"), book.series, meta_w),
        metaRow(_("进度"), string.format("%.0f%%", pct), meta_w),
    }
    for _, row in ipairs(rows) do
        if row then
            table.insert(meta_kids, row)
            table.insert(meta_kids, VerticalSpan:new{ width = UI.sz(6) })
        end
    end
    table.insert(meta_kids, VerticalSpan:new{ width = UI.sz(8) })
    table.insert(meta_kids, UI.progressBar(meta_w, UI.sz(8), pct))

    local header = HorizontalGroup:new{
        align = "top",
        cover_w,
        HorizontalSpan:new{ width = UI.sz(14) },
        LeftContainer:new{
            dimen = Geom:new{ w = meta_w, h = math.max(ch, UI.sz(120)) },
            VerticalGroup:new(meta_kids),
        },
    }

    local body_kids = {
        align = "left",
        header,
    }

    local desc = book.description or book.intro or book.summary
    if desc and desc ~= "" then
        table.insert(body_kids, VerticalSpan:new{ width = UI.sz(18) })
        table.insert(body_kids, LineWidget:new{
            background = Blitbuffer.gray(0.8),
            dimen = Geom:new{ w = content_w, h = Size.line.thin },
        })
        table.insert(body_kids, VerticalSpan:new{ width = UI.sz(10) })
        table.insert(body_kids, sectionTitle(_("简介"), content_w))
        table.insert(body_kids, VerticalSpan:new{ width = UI.sz(6) })
        table.insert(body_kids, TextBoxWidget:new{
            text = desc,
            face = UI.face("xx_smallinfofont", 14),
            width = content_w,
            alignment = "left",
            fgcolor = Blitbuffer.gray(0.3),
        })
    end
    table.insert(body_kids, VerticalSpan:new{ width = UI.sz(20) })

    local body = VerticalGroup:new(body_kids)
    local body_size = body:getSize()

    local inner
    if ScrollableContainer then
        self.cropping_widget = ScrollableContainer:new{
            dimen = Geom:new{ w = w, h = scroll_h },
            show_parent = self,
            FrameContainer:new{
                bordersize = 0,
                padding = pad,
                padding_top = UI.sz(12),
                background = Blitbuffer.COLOR_WHITE,
                LeftContainer:new{
                    dimen = Geom:new{
                        w = content_w,
                        h = math.max(body_size.h, 1),
                    },
                    body,
                },
            },
        }
        inner = self.cropping_widget
    else
        inner = FrameContainer:new{
            bordersize = 0,
            padding = pad,
            padding_top = UI.sz(12),
            background = Blitbuffer.COLOR_WHITE,
            dimen = Geom:new{ w = w, h = scroll_h },
            body,
        }
    end

    local footer = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = w, h = footer_h },
        VerticalGroup:new{
            align = "center",
            LineWidget:new{
                background = Blitbuffer.gray(0.75),
                dimen = Geom:new{ w = w, h = Size.line.medium },
            },
            FrameContainer:new{
                bordersize = 0,
                padding = pad,
                padding_top = UI.sz(8),
                padding_bottom = pad,
                background = Blitbuffer.COLOR_WHITE,
                buttons,
            },
        },
    }

    self[1] = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = w, h = h },
        VerticalGroup:new{
            align = "left",
            title_bar,
            inner,
            footer,
        },
    }
    self.dimen = Geom:new{ x = 0, y = 0, w = w, h = h }
end

return Detail
