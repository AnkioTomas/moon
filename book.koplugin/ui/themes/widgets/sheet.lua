--[[--
主题动作表（替代 ButtonDialog）：标题 + 一列通栏按钮，超高自动分页，点按即关窗再执行。

  +----------------------+
  | 标题（可选）         |
  | [      动作一      ] |
  | [ 复制 ][ 高亮 ][ 查词 ] |   buttons 项：一行等宽按钮（ButtonDialog 的二维 buttons）
  |                      |   separator 项留一段空隙分组；widget 项放任意正文
  | [      删除        ] |
  +----------------------+

  Sheet:new{ title = "…", items = {
      { text = "打开", callback = fn },
      { buttons = { { text = "复制", callback = fn }, { icon = "share", callback = fn } } },
      { separator = true },
      { widget = function(width) return Text.box("body", "…", width, { bg = t.dialog.bg }) end },
      { text = "删除", variant = "primary", callback = fn, enabled = true },
  } }:show()

  贴着按钮弹出的菜单：Sheet:new{ anchor = button.dimen, items = … }

@module koplugin.book.ui.themes.widgets.sheet
--]]

local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local UIManager = require("ui/uimanager")
local Theme = require("ui.themes")
local Button = require("ui.themes.widgets.button")
local Modal = require("ui.themes.widgets.modal")
local Pager = require("ui.themes.widgets.pager")

---@class BookThemeSheet : BookThemeModal
---@field title string|nil
---@field items table[]
---@field page integer
---@field pages table[][]
local Sheet = Modal:extend{
    title = nil,
    items = nil,
}

function Sheet:init()
    Modal.init(self)
    self.page = 1
    self:updateView()
end

--- 按实测高度装页；分隔符跟着下一行，页首不留空分组。
---@param rows table[]
---@param height number
---@return table[][]
local function pack(rows, height)
    local pages, page, used = {}, {}, 0
    for _idx, row in ipairs(rows) do
        local gap = #page > 0 and row.gap or 0
        local h = row.widget:getSize().h
        if #page > 0 and used + gap + h > height then
            pages[#pages + 1], page, used, gap = page, {}, 0, 0
        end
        if gap > 0 then page[#page + 1] = VerticalSpan:new{ width = gap } end
        page[#page + 1] = row.widget
        used = used + gap + h
    end
    pages[#pages + 1] = page
    return pages
end

function Sheet:updateView()
    local t = self.theme
    local width = self:innerWidth()
    local gap = Theme.px(t.space.xs)
    local rows, spacing = {}, gap
    for _idx, item in ipairs(self.items) do
        local widget
        if item.separator then
            spacing = spacing + gap + Theme.px(t.space.md)
        elseif item.widget then
            widget = item.widget(width)
        elseif item.buttons then
            local specs = {}
            for i, spec in ipairs(item.buttons) do
                specs[i] = {
                    text = spec.text, icon = spec.icon, variant = spec.variant, enabled = spec.enabled,
                    callback = function()
                        self:close()
                        if spec.callback then spec.callback() end
                    end,
                }
            end
            widget = self:buttonRow(specs, width)
        else
            widget = Button:new{
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
        if widget then
            rows[#rows + 1] = { widget = widget, gap = spacing }
            spacing = gap
        end
    end
    self:setDialog{ title = self.title }
    local room = self.dimen.h
    local a = self.anchor
    if type(a) == "table" then room = math.max(a.y, self.dimen.h - a.y - a.h) end
    local available = room - Theme.px(t.space.sm) * 2 - self[1]:getSize().h
    self.pages = pack(rows, available)
    if #self.pages > 1 then
        self.pages = pack(rows, available - Theme.px(t.control.height))
    end
    self.page = math.max(1, math.min(#self.pages, self.page))
    self:rebuild()
end

function Sheet:rebuild()
    local body = VerticalGroup:new{ align = "left" }
    for _idx, widget in ipairs(self.pages[self.page]) do body[#body + 1] = widget end
    if #self.pages > 1 then
        local height = 0
        for _idx, page in ipairs(self.pages) do
            local used = 0
            for _i, widget in ipairs(page) do used = used + widget:getSize().h end
            height = math.max(height, used)
        end
        local used = body:getSize().h
        body[#body + 1] = VerticalSpan:new{ width = height - used }
        body[#body + 1] = Pager.widget({
            width = self:innerWidth(), page = self.page, pages = #self.pages, range = self.dimen,
            on_page = function(page) self:goPage(page) end,
        })
        body:resetLayout()
    end
    self:setDialog{ title = self.title, body = body }
end

---@param page integer
function Sheet:goPage(page)
    self.page = math.max(1, math.min(#self.pages, page))
    self:rebuild()
    UIManager:setDirty(self.show_parent or self, "ui")
end

return Sheet
