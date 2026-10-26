--[[-- 阅读页快捷面板书籍信息头：左边封面，右边书名、作者、章节、进度，最右退出。
@module koplugin.book.features.panel.widget.header
--]]

require("l10n").apply()

local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local lfs = require("libs/libkoreader-lfs")
local Button = require("ui.themes.widgets.button")
local Image = require("ui.themes.widgets.image")
local Progress = require("ui.themes.widgets.progress")
local Text = require("ui.themes.widgets.text")
local Theme = require("ui.themes")
local Paths = require("utils.paths")
local Session = require("reader.session")
local _ = require("gettext")

local COVER_W, COVER_H = 66, 92

--- 阅读页快捷面板头部：封面、书籍信息、阅读进度和退出阅读按钮。
---@class BookQuickPanelHeader : WidgetContainer
---@field height number 头部高度，单位像素
---@field width number 头部宽度，单位像素
---@field on_exit fun()|nil 点击退出阅读

local Header = InputContainer:extend{
    name = "book_quick_panel_header",
}

--- 当前会话的书名、作者、章节行、进度行与百分比；章节行没有目录时为空串。
---@return table
local function bookInfo()
    local current = Session.current()
    local identity = current and current.identity
    local book = identity and identity.book or {}
    local chapter = ""
    local idx, toc = Session.chapterIndex(), Session.toc()
    if idx and toc then
        chapter = Session.chapterTitle() or string.format(_("第 %d/%d 章"), idx, #toc)
    end
    local page, total = Session.bookPages()
    local percent = current and current.percent or 0
    local progress = string.format("%d%%", math.floor(percent + 0.5))
    if total > 0 then
        progress = string.format(_("第 %d/%d 页"), page, total) .. " · " .. progress
    end
    return {
        title = book.title or _("阅读"),
        authors = book.authors or "",
        chapter = chapter,
        progress = progress,
        percent = percent,
        cover = identity and Paths.coverPath(identity.stable_id, identity.source_id),
    }
end

--- 构建封面、信息列与退出按钮。
---@param self BookQuickPanelHeader 当前视图或布局实例
function Header:init()
    local info = bookInfo()
    local t = Theme.current()
    local gap = Theme.px(t.space.md)
    local cover_w, cover_h = Theme.px(COVER_W), Theme.px(COVER_H)
    local exit = Button:new{
        icon = "logout", text = _("退出"), callback = self.on_exit,
    }
    local text_w = self.width - cover_w - exit:getSize().w - gap * 2
    local cover_src = info.cover and lfs.attributes(info.cover, "mode") == "file" and info.cover or nil

    local column = VerticalGroup:new{
        align = "left",
        Text.line("title", info.title, { width = text_w }),
    }
    for _idx, line in ipairs({ info.authors, info.chapter }) do
        if line ~= "" then
            column[#column + 1] = Text.line("caption", line, { width = text_w, color = t.color.muted })
        end
    end
    column[#column + 1] = VerticalSpan:new{ width = Theme.px(t.space.xs) }
    column[#column + 1] = Text.line("caption", info.progress, { width = text_w })
    column[#column + 1] = VerticalSpan:new{ width = Theme.px(t.space.xs) }
    column[#column + 1] = Progress:new{ width = text_w, percent = info.percent }

    local height = math.max(cover_h, column:getSize().h)
    self.height = height
    self.dimen = Geom:new{ w = self.width, h = height }
    self[1] = HorizontalGroup:new{
        align = "center",
        Image.widget{ width = cover_w, height = cover_h, src = cover_src, fallback = info.title },
        HorizontalSpan:new{ width = gap },
        LeftContainer:new{ dimen = Geom:new{ w = text_w, h = height }, column },
        HorizontalSpan:new{ width = gap },
        exit,
    }
end

---@type BookQuickPanelHeader
return Header
