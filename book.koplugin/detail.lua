--[[--
书籍详情：封面 / 元数据 / 开始阅读

@module koplugin.book.detail
--]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Cover = require("cover")
local UI = require("bookui")
local _ = require("gettext")
local Screen = Device.screen

local Detail = InputContainer:extend{
    name = "book_detail",
    covers_fullscreen = true,
    book = nil,
    plugin = nil,
    api = nil,
    desktop = nil,
}

local function field(label, value, width)
    if not value or value == "" then
        return nil
    end
    return TextWidget:new{
        text = label .. value,
        face = UI.face("cfont", 16),
        max_width = width,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
end

function Detail:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self:rebuild()
end

function Detail:getSize()
    return self.dimen
end

function Detail:rebuild()
    local book = self.book or {}
    local w = Screen:getWidth()
    local h = Screen:getHeight()
    local pad = UI.sz(20)
    local cw = UI.sz(140)
    local ch = UI.sz(200)
    local title = book.bookName or book.filename or book.fileName or "?"
    local filename = book.filename or book.fileName or book.file or book.path
    local path = Cover.cachedPath(self.plugin, filename)
    local cover_w = Cover.widget(path, cw, ch, title)
    if not path and filename then
        Cover.ensureAsync(self.api, self.plugin, filename, nil)
    end

    local pct = tonumber(book.progressPercent) or 0
    if type(book.progressPercent) == "string" then
        pct = tonumber((book.progressPercent:gsub("%%", ""):match("[%d%.]+"))) or 0
    end
    if pct < 0 then pct = 0 end
    if pct > 100 then pct = 100 end
    local info_w = math.max(UI.sz(40), w - pad * 2)
    local kids = {
        align = "center",
        cover_w,
        VerticalSpan:new{ width = UI.sz(16) },
        TextBoxWidget:new{
            text = title,
            face = UI.face("cfont", 22),
            width = info_w,
            alignment = "center",
            fgcolor = Blitbuffer.COLOR_BLACK,
        },
        VerticalSpan:new{ width = UI.sz(10) },
    }

    local rows = {
        field(_("作者："), book.author, info_w),
        field(_("分类："), book.category, info_w),
        field(_("系列："), book.series, info_w),
        field(_("进度："), string.format("%.0f%%", pct), info_w),
    }
    for _, row in ipairs(rows) do
        if row then
            table.insert(kids, row)
            table.insert(kids, VerticalSpan:new{ width = UI.sz(6) })
        end
    end

    local desc = book.description or book.intro or book.summary
    if desc and desc ~= "" then
        table.insert(kids, VerticalSpan:new{ width = UI.sz(8) })
        table.insert(kids, TextBoxWidget:new{
            text = desc,
            face = UI.face("xx_smallinfofont", 14),
            width = info_w,
            alignment = "left",
            fgcolor = Blitbuffer.gray(0.35),
        })
    end

    table.insert(kids, VerticalSpan:new{ width = UI.sz(20) })
    table.insert(kids, UI.progressBar(info_w, UI.sz(10), pct))
    table.insert(kids, VerticalSpan:new{ width = UI.sz(24) })

    local buttons = ButtonTable:new{
        width = info_w,
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
        show_parent = self,
    }
    table.insert(kids, buttons)

    self[1] = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = w, h = h },
        CenterContainer:new{
            dimen = Geom:new{ w = w, h = h },
            FrameContainer:new{
                bordersize = 0,
                padding = pad,
                background = Blitbuffer.COLOR_WHITE,
                VerticalGroup:new(kids),
            },
        },
    }
    self.dimen = Geom:new{ x = 0, y = 0, w = w, h = h }
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

function Detail:onTapClose()
    self:onClose()
    return true
end

return Detail
