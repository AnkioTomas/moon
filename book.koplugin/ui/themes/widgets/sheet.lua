--[[--
主题动作表（替代 ButtonDialog）：标题 + 一列通栏按钮，点按即关窗再执行。

  +----------------------+
  | 标题（可选）         |
  | [      动作一      ] |
  | [      动作二      ] |
  |                      |   separator 项留一段空隙分组
  | [      删除        ] |
  +----------------------+

  Sheet:new{ title = "…", items = {
      { text = "打开", callback = fn },
      { separator = true },
      { text = "删除", variant = "primary", callback = fn, enabled = true },
  } }:show()

@module koplugin.book.ui.themes.widgets.sheet
--]]

local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Theme = require("ui.themes.init")
local Button = require("ui.themes.widgets.button")
local Modal = require("ui.themes.widgets.modal")

---@class BookThemeSheet : BookThemeModal
---@field title string|nil
---@field items table[]
local Sheet = Modal:extend{
    title = nil,
    items = nil,
}

function Sheet:init()
    Modal.init(self)
    local t = self.theme
    local width = self:innerWidth()
    local gap = Theme.px(t.space.xs)
    local body = VerticalGroup:new{ align = "left" }
    for _, item in ipairs(self.items) do
        if #body > 0 then body[#body + 1] = VerticalSpan:new{ width = gap } end
        if item.separator then
            body[#body + 1] = VerticalSpan:new{ width = Theme.px(t.space.md) }
        else
            body[#body + 1] = Button:new{
                text = item.text,
                icon = item.icon,
                variant = item.variant or "normal",
                enabled = item.enabled ~= false,
                width = width,
                callback = function()
                    self:close()
                    if item.callback then item.callback() end
                end,
            }
        end
    end
    self:setDialog{ title = self.title, body = body }
end

return Sheet
