--[[-- 阅读页快捷面板书籍信息头。
@module koplugin.book.features.panel.widget.header
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
local VerticalGroup = require("ui/widget/verticalgroup")
local Icon = require("ui.themes.widgets.icon")
local Box = require("ui.themes.widgets.box")
local Text = require("ui.themes.widgets.text")
local Theme = require("ui.themes")
local Session = require("reader.session")
local _ = require("gettext")

--- 阅读页快捷面板头部：标题、副标题和退出阅读按钮。
---@class BookQuickPanelHeader : WidgetContainer
---@field width number 头部宽度，单位像素
---@field height number 头部高度，单位像素
---@field on_exit fun()|nil 点击退出阅读

local Header = InputContainer:extend{
    name = "book_quick_panel_header",
}

--- 从当前阅读会话提取书名和章节/作者副标题。
---@return string, string|nil
local function bookTexts()
    local current = Session.current()
    local identity = current and current.identity
    local toc = Session.toc()
    local title = (identity and identity.book and identity.book.title) or _("阅读")
    local subtitle = ""
    local idx = Session.chapterIndex()
    if idx and toc then
        subtitle = string.format(_("第 %d/%d 章"), idx, #toc)
        local chapter_title = Session.chapterTitle()
        if chapter_title then
            subtitle = chapter_title
        end
    elseif identity and identity.book and identity.book.author then
        subtitle = identity.book.author
    end
    return title, subtitle
end

--- 构建标题文本和退出按钮布局。
---@param self BookQuickPanelHeader 当前视图或布局实例
function Header:init()
    local title, subtitle = bookTexts()
    local t = Theme.current()
    local exit_w = Theme.px(t.control.height)
    local gap = Theme.px(t.space.sm)
    local text_w = self.width - exit_w - gap
    local title_w = Text.line("title", title, { width = text_w })
    local info_group = VerticalGroup:new{
        align = "left",
        title_w,
    }
    if subtitle ~= "" then
        info_group[#info_group + 1] = Text.line("caption", subtitle, {
            width = text_w, color = t.color.muted,
        })
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
    local v = t.button.normal
    exit_btn[1] = CenterContainer:new{
        dimen = Geom:new{ w = exit_w, h = self.height },
        Box:new{
            style = {
                bg = v.bg,
                border = v.border_color and t.control.border or 0,
                border_color = v.border_color or 0,
                radius = 999,
                shadow = 0,
                shadow_color = 0,
            },
            width = exit_w,
            height = Theme.px(t.control.height),
            Icon.widget{
                name = "close",
                size = t.control.icon,
                color = Blitbuffer.Color8(v.ink),
            },
        },
    }
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self[1] = HorizontalGroup:new{
        align = "center",
        LeftContainer:new{
            dimen = Geom:new{ w = text_w, h = self.height },
            info_group,
        },
        HorizontalSpan:new{ width = gap },
        exit_btn,
    }
end

---@type BookQuickPanelHeader
return Header
