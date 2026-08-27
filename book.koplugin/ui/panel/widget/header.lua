--[[-- 阅读页快捷面板书籍信息头。
@module koplugin.book.ui.panel.widget.header
--]]

require("l10n").apply()

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local Icon = require("ui.components.icon")
local Surface = require("ui.components.surface")
local UI = require("ui.components.bookui")
local Session = require("ui.reader.session")
local _ = require("gettext")

--- 阅读页快捷面板头部：标题、副标题和退出阅读按钮。
---@class BookQuickPanelHeader : WidgetContainer
---@field width number
---@field height number
---@field ui table|nil
---@field on_exit fun()|nil

local Header = InputContainer:extend{
    name = "book_quick_panel_header",
}

--- 从当前阅读会话提取书名和章节/作者副标题。
---@param ui table|nil
---@return string, string
local function bookTexts(ui)
    local current = Session.current() or {}
    local identity = current.identity
    local toc = Session.toc()
    local title = (identity and identity.book and identity.book.title) or _("阅读")
    local subtitle = ""
    local idx = Session.chapterIndex()
    if idx and toc then
        subtitle = string.format(_("第 %d/%d 章"), idx, #toc)
    elseif identity and identity.book and identity.book.author then
        subtitle = identity.book.author
    end
    return title, subtitle
end

--- 构建标题文本和退出按钮布局。
---@param self BookQuickPanelHeader
---@return void
function Header:init()
    local title, subtitle = bookTexts(self.ui)
    local exit_w = UI.sz(44)
    local text_w = self.width - exit_w - UI.sz(8)
    local title_w = TextWidget:new{
        text = title,
        face = UI.face("cfont", 15),
        fgcolor = Blitbuffer.COLOR_BLACK,
        max_width = text_w,
    }
    local info_group = VerticalGroup:new{
        align = "left",
        title_w,
    }
    if subtitle ~= "" then
        info_group[#info_group + 1] = TextWidget:new{
            text = subtitle,
            face = UI.face("xx_smallinfofont", 12),
            fgcolor = UI.muted(),
            max_width = text_w,
        }
    end
    -- range 必须复用 dimen 同一 Geom，布局时 x/y 才会回填，否则叉号命中区永远落在 (0,0)。
    local exit_dimen = Geom:new{ w = exit_w, h = self.height }
    local exit_btn = InputContainer:new{
        dimen = exit_dimen,
        ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = exit_dimen } },
        },
    }
    --- 点击退出按钮时关闭阅读会话。
    ---@return boolean
    function exit_btn:onTap()
        if self.on_exit then self.on_exit() end
        return true
    end
    exit_btn.on_exit = self.on_exit
    exit_btn[1] = CenterContainer:new{
        dimen = Geom:new{ w = exit_w, h = self.height },
        Surface.pill(Icon.widget{
            name = "close",
            size = 22,
            color = Blitbuffer.COLOR_BLACK,
        }, {
            width = exit_w,
            height = UI.sz(36),
            background = UI.surface(),
            shadow = false,
        }),
    }
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self[1] = HorizontalGroup:new{
        align = "center",
        LeftContainer:new{
            dimen = Geom:new{ w = text_w, h = self.height },
            info_group,
        },
        HorizontalSpan:new{ width = UI.sz(8) },
        exit_btn,
    }
end

---@type BookQuickPanelHeader
return Header
