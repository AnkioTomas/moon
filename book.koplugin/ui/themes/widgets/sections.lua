--[[--
主题分组页（替代 components/pager 的 pack + frame）：分组标题 + 行，按高度切页，翻页条钉在底部。
行高不一（有无副标题），所以按实测高度装页，不按固定行距。

  +-------------------------------+
  | 书库                          |   分组标题：caption，muted
  | [icon] 书籍来源      微信  >  |
  | [icon] 账号与登录          >  |
  |                               |   分组间隔 space.md
  | 桌面                          |
  | …                             |
  | [<]        1 / 3         [>]  |   只有一页时不画
  +-------------------------------+

  local body, page = Sections.widget({
      width = w, height = h, page = self.page,
      sections = { { title = "书库", rows = { function(width) return Row.widget({ width = width, … }) end } } },
      on_page = function(p) self.page = p; redraw() end,
  })

行是构建函数：按页宽现建。标题和它的第一行绑在一起，不会单独落在页尾。

@module koplugin.book.ui.themes.widgets.sections
--]]

local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Theme = require("ui.themes.init")
local Box = require("ui.themes.widgets.box")
local Pager = require("ui.themes.widgets.pager")
local Text = require("ui.themes.widgets.text")

---@class BookThemeSection
---@field title string
---@field rows (fun(width: number): table)[]

---@class BookThemeSections
local Sections = {}

--- 分组标题块：间隔（首组没有）+ 标题 + 首行。
---@param t table 主题令牌
---@param section BookThemeSection
---@param width number
---@param first boolean
---@return table
local function head(t, section, width, first)
    local pad = Theme.px(t.space.md)
    local block = VerticalGroup:new{ align = "left" }
    if not first then block[#block + 1] = VerticalSpan:new{ width = Theme.px(t.space.md) } end
    block[#block + 1] = LeftContainer:new{
        dimen = Geom:new{ w = width, h = Theme.px(t.font.caption) + pad * 2 },
        HorizontalGroup:new{
            HorizontalSpan:new{ width = pad },
            Text.line("caption", section.title, { width = width - pad * 2, color = t.color.muted }),
        },
    }
    if section.rows[1] then block[#block + 1] = section.rows[1](width) end
    return block
end

--- 按可用高度把块装进页；每页至少一块（超高的块独占一页）。
---@param blocks table[]
---@param avail number
---@return table[][]
local function pack(blocks, avail)
    local pages, cur, used = {}, {}, 0
    for _idx, block in ipairs(blocks) do
        local h = block:getSize().h
        if #cur > 0 and used + h > avail then
            pages[#pages + 1], cur, used = cur, {}, 0
        end
        cur[#cur + 1] = block
        used = used + h
    end
    pages[#pages + 1] = cur
    return pages
end

---@param opts { width: number, height: number, sections: BookThemeSection[], page: integer|nil, on_page: fun(page: integer) }
---@return table widget
---@return integer page 夹进 [1, pages] 后的页码
---@return integer pages
function Sections.widget(opts)
    local t = Theme.current()
    local w, h = opts.width, opts.height
    local blocks = {}
    for i, section in ipairs(opts.sections) do
        blocks[#blocks + 1] = head(t, section, w, i == 1)
        for j = 2, #section.rows do blocks[#blocks + 1] = section.rows[j](w) end
    end
    local pages = pack(blocks, h)
    local pager_h = Theme.px(t.control.height)
    if #pages > 1 then pages = pack(blocks, h - pager_h) end
    local page = math.max(1, math.min(#pages, opts.page or 1))
    local body = VerticalGroup:new{ align = "left" }
    for _idx, block in ipairs(pages[page]) do body[#body + 1] = block end
    local bar_h = #pages > 1 and pager_h or 0
    local group = VerticalGroup:new{
        align = "left",
        body,
        VerticalSpan:new{ width = math.max(0, h - bar_h - body:getSize().h) },
    }
    if #pages > 1 then
        group[#group + 1] = Pager.widget({
            width = w, page = page, pages = #pages,
            on_prev = function() opts.on_page(page - 1) end,
            on_next = function() opts.on_page(page + 1) end,
        })
    end
    return Box:new{ style = { bg = t.color.page }, width = w, height = h, group }, page, #pages
end

return Sections
