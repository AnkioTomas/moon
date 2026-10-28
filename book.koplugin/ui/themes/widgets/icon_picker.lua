--[[--
主题图标选择器：全屏网格，列出图标字体里的全部图标（icon/names.lua），按英文名搜索，分页不滚动。

  +-------------------------------+
  | [🔍]      选择图标        [×] |   左键搜索：弹输入框，按名字子串过滤；留空恢复全部
  |          共 3970 个           |   副标题：总数，或「关键词」：命中数
  |-------------------------------|
  |  🏠    📖    ⚙    🔍    ★     |
  | home  book  sett… search star |   当前图标取 selected 令牌（mark > 0 时格底画指示条）
  |  …                            |
  | [<]        1 / 95        [>]  |
  +-------------------------------+

打开时翻到 current 所在页；点一格先关窗再 on_select(name)；左右滑翻页。

  IconPicker:new{ title = "选择图标", current = "home", on_select = function(name) end }:show()

名字表由 tools/build_icon_names.py 从字体生成，每个字形只留一个名字；换字体后重跑。

@module koplugin.book.ui.themes.widgets.icon_picker
--]]

require("l10n").apply()

local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Theme = require("ui.themes")
local Box = require("ui.themes.widgets.box")
local Icon = require("ui.themes.widgets.icon")
local Input = require("ui.themes.widgets.input")
local Modal = require("ui.themes.widgets.modal")
local Pager = require("ui.themes.widgets.pager")
local Tap = require("ui.themes.widgets.tap")
local Text = require("ui.themes.widgets.text")
local TitleBar = require("ui.themes.widgets.titlebar")
local NAMES = require("ui.themes.widgets.icon.names")
local _ = require("gettext")
local T = require("ffi/util").template

---@class BookThemeIconPicker : BookThemeModal
---@field title string|nil
---@field current string|nil 当前图标名
---@field on_select fun(name: string)|nil
---@field query string 当前搜索词（已规范化）
---@field names string[] 过滤后的名字
---@field page integer
local IconPicker = Modal:extend{
    covers_fullscreen = true,
    title = nil,
    current = nil,
    on_select = nil,
}

--- 搜索词规范化：小写、去首尾空白、中间空白当下划线（图标名的分词符）。
---@param text string
---@return string
local function normalize(text)
    return (text:lower():gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", "_"))
end

function IconPicker:init()
    Modal.init(self)
    local t = self.theme
    self.cell = Theme.px(t.row.height * 2)
    self.cols = math.max(1, math.floor(self.dimen.w / self.cell))
    self.cell_w = math.floor(self.dimen.w / self.cols)
    local body_h = self.dimen.h - TitleBar.height() - Theme.px(t.control.height)
    self.per_page = self.cols * math.max(1, math.floor(body_h / self.cell))
    self.query = ""
    self.names = NAMES
    self.page = self:currentPage()
    self:rebuild()
end

---@return integer
function IconPicker:pages()
    return math.max(1, math.ceil(#self.names / self.per_page))
end

--- current 所在页；不在当前结果里则第 1 页。
---@return integer
function IconPicker:currentPage()
    for i, name in ipairs(self.names) do
        if name == self.current then return math.ceil(i / self.per_page) end
    end
    return 1
end

--- 按名字子串过滤（plain 匹配，不当 Lua 模式），停在 current 所在页。
---@param text string
function IconPicker:search(text)
    self.query = normalize(text)
    if self.query == "" then
        self.names = NAMES
    else
        local hits = {}
        for _idx, name in ipairs(NAMES) do
            if name:find(self.query, 1, true) then hits[#hits + 1] = name end
        end
        self.names = hits
    end
    self:goPage(self:currentPage())
end

function IconPicker:askQuery()
    Input:new{
        title = _("搜索图标"),
        fields = { { text = self.query, hint = _("英文名，如 book；留空显示全部") } },
        callback = function(text) self:search(text) end,
    }:show()
end

---@param name string
function IconPicker:choose(name)
    self:close()
    if self.on_select then self.on_select(name) end
end

--- 一格：图标 + 名字；当前项取 selected 令牌，mark > 0 时格底画指示条。
---@param name string
---@return table
function IconPicker:cellWidget(name)
    local t = self.theme
    local sel = t.selected
    local active = name == self.current
    local mark = Theme.px(sel.mark)
    local ink = Theme.color(active and sel.ink or t.color.accent)
    local cell = VerticalGroup:new{
        align = "center",
        Box:new{
            style = { bg = active and sel.bg or nil }, keep_bg = active,
            width = self.cell_w,
            height = self.cell - mark,
            Icon.label{
                name = name,
                text = name,
                direction = "column",
                size = t.control.icon + t.space.sm,
                color = ink,
                font_size = t.font.caption,
                max_width = self.cell_w - Theme.px(t.space.xs) * 2,
                gap = Theme.px(t.space.xs),
            },
        },
    }
    if mark > 0 then
        cell[#cell + 1] = CenterContainer:new{
            dimen = Geom:new{ w = self.cell_w, h = mark },
            Box:new{
                style = { bg = active and t.color.accent or t.color.page },
                width = math.floor(self.cell_w / 3), height = mark, keep_bg = true,
            },
        }
    end
    return Tap.wrap(cell, function() self:choose(name) end)
end

--- 按当前页重建：标题栏、网格、底部翻页条（多于一页才画），中间补空把翻页条钉在底部。
function IconPicker:rebuild()
    local t = self.theme
    local w = self.dimen.w
    local count = #self.names
    local bar = TitleBar.widget({
        width = w,
        title = self.title or _("选择图标"),
        subtitle = self.query == "" and T(_("共 %1 个"), count) or T(_("「%1」：%2 个"), self.query, count),
        left_icon = "search",
        left_callback = function() self:askQuery() end,
        right_icon = "close",
        right_callback = function() self:dismiss() end,
    })
    local grid = VerticalGroup:new{ align = "left" }
    local first = (self.page - 1) * self.per_page
    local line
    for i = first + 1, math.min(count, first + self.per_page) do
        if (i - first - 1) % self.cols == 0 then
            line = HorizontalGroup:new{ align = "top" }
            grid[#grid + 1] = line
        end
        line[#line + 1] = self:cellWidget(self.names[i])
    end
    if count == 0 then
        grid[1] = CenterContainer:new{
            dimen = Geom:new{ w = w, h = self.cell },
            Text.line("body", _("没有匹配的图标"), { width = w, color = t.color.muted }),
        }
    end
    local pages = self:pages()
    local pager = pages > 1 and Pager.widget({
        width = w,
        page = self.page,
        pages = pages,
        range = self.dimen,
        on_page = function(page) self:goPage(page) end,
    })
    local used = bar:getSize().h + grid:getSize().h + (pager and pager:getSize().h or 0)
    local page = VerticalGroup:new{
        align = "left",
        bar,
        grid,
        VerticalSpan:new{ width = math.max(0, self.dimen.h - used) },
    }
    if pager then page[#page + 1] = pager end
    self:setPanel(Box:new{ style = { bg = t.color.page }, width = w, height = self.dimen.h, page })
end

---@param page integer
function IconPicker:goPage(page)
    self.page = math.max(1, math.min(self:pages(), page))
    self:rebuild()
    UIManager:setDirty(self.show_parent or self, "ui")
end

return IconPicker
