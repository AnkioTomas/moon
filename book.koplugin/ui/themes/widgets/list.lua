--[[--
主题选项列表（替代 Menu / Popup.list）：分页不滚动，单选或多选。

  全屏（默认）                         居中（centered=true）
  +-------------------------------+    +---------------------+
  | [<]       标题          [×]   |    | 标题                |
  |-------------------------------|    | (o) 选项一          |
  | (o) 选项一          当前值 >  |    | (•) 选项二          |
  | (•) 选项二                    |    | [<]   1 / 2    [>]  |
  | …                             |    +---------------------+
  | [<]        1 / 3         [>]  |
  +-------------------------------+

subtitle 只在全屏标题栏里显示；居中面板点外面关，全屏点右上角或返回键关。
items：{ text, value, icon, mandatory（右侧状态字）, widget（右侧控件，优先于 mandatory）,
         image / image_w / image_h（缩略图，逻辑像素）, enabled, checked }
  checked 为 nil 的项不画选择标记；非 nil 时单选画 radio、多选画 checkbox。
单选：点按即关窗，再 on_select(value, item)；打开时翻到第一个 checked 项所在页，该项按选中样式画。
多选：点按就地翻转 item.checked（会改调用方的 items）并 on_toggle(value, checked, item)，不关窗；
      结果在 close_callback 里读 items。

  List:new{ title = "排序", items = items, on_select = fn }:show()
  list:setItems(items)   -- 异步加载后替换内容，停留在原页（越界则夹到末页）

@module koplugin.book.ui.themes.widgets.list
--]]

local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Theme = require("ui.themes.init")
local Box = require("ui.themes.widgets.box")
local Modal = require("ui.themes.widgets.modal")
local Pager = require("ui.themes.widgets.pager")
local Row = require("ui.themes.widgets.row")
local TitleBar = require("ui.themes.widgets.titlebar")

---@class BookThemeList : BookThemeModal
---@field title string|nil
---@field subtitle string|nil
---@field items table[]
---@field multi boolean
---@field centered boolean
---@field on_select fun(value: any, item: table)|nil
---@field on_toggle fun(value: any, checked: boolean, item: table)|nil
---@field page integer
---@field per_page integer
local List = Modal:extend{
    title = nil,
    subtitle = nil,
    items = nil,
    multi = false,
    centered = false,
    on_select = nil,
    on_toggle = nil,
}

function List:init()
    self.mask = self.centered
    Modal.init(self)
    local t = self.theme
    local pad = Theme.px(t.space.lg)
    self.row_w = self.centered and self:innerWidth() or self.dimen.w
    self.pitch = Row.height(false) + Theme.px(t.row.divider)
    local chrome = Theme.px(t.control.height)                      -- 翻页条
        + (self.centered and pad * 4 + Theme.px(t.font.title * 2)   -- 面板边距 + 标题
            or TitleBar.height())
    self.per_page = math.max(1, math.floor((self.dimen.h - chrome) / self.pitch))
    self.page = 1
    for i, item in ipairs(self.items) do
        if item.checked then
            self.page = math.ceil(i / self.per_page)
            break
        end
    end
    self:rebuild()
end

---@return integer
function List:pages()
    return math.max(1, math.ceil(#self.items / self.per_page))
end

--- 选择标记图标；checked 为 nil 时用项自己的 icon。
---@param item table
---@return string|nil
function List:markIcon(item)
    if item.checked == nil then return item.icon end
    if self.multi then return item.checked and "check_box" or "check_box_outline_blank" end
    return item.checked and "radio_button_checked" or "radio_button_unchecked"
end

---@param item table
function List:choose(item)
    if self.multi then
        item.checked = not item.checked
        if self.on_toggle then self.on_toggle(item.value, item.checked, item) end
        self:rebuild()
        UIManager:setDirty(self, "ui")
        return
    end
    self:close()
    if self.on_select then self.on_select(item.value, item) end
end

--- 按当前页重建面板。
function List:rebuild()
    local t = self.theme
    local pages = self:pages()
    local rows = VerticalGroup:new{ align = "left" }
    local first = (self.page - 1) * self.per_page
    for i = first + 1, math.min(#self.items, first + self.per_page) do
        local item = self.items[i]
        rows[#rows + 1] = Row.widget({
            width = self.row_w,
            icon = self:markIcon(item),
            image = item.image,
            image_w = item.image_w,
            image_h = item.image_h,
            title = item.text,
            status = item.widget or item.mandatory,
            chevron = false,
            selected = not self.multi and item.checked == true,
            enabled = item.enabled,
            callback = function() self:choose(item) end,
        })
    end
    local pager = pages > 1 and Pager.widget({
        width = self.row_w,
        page = self.page,
        pages = pages,
        on_prev = function() self:goPage(self.page - 1) end,
        on_next = function() self:goPage(self.page + 1) end,
    })
    if self.centered then
        local body = VerticalGroup:new{ align = "left", rows }
        if pager then body[#body + 1] = pager end
        self:setDialog{ title = self.title, body = body }
        return
    end
    -- 全屏：翻页条钉在底部，行不满一页时中间补空。
    local bar = TitleBar.widget({
        width = self.row_w, title = self.title, subtitle = self.subtitle,
        right_icon = "close", right_callback = function() self:dismiss() end,
    })
    local used = bar:getSize().h + rows:getSize().h + (pager and pager:getSize().h or 0)
    local page = VerticalGroup:new{
        align = "left",
        bar,
        rows,
        VerticalSpan:new{ width = math.max(0, self.dimen.h - used) },
    }
    if pager then page[#page + 1] = pager end
    self:setPanel(Box:new{ style = { bg = t.color.page }, width = self.dimen.w, height = self.dimen.h, page })
end

---@param page integer
function List:goPage(page)
    self.page = math.max(1, math.min(self:pages(), page))
    self:rebuild()
    UIManager:setDirty(self, "ui")
end

--- 替换全部项，停在原页（越界夹到末页）。
---@param items table[]
function List:setItems(items)
    self.items = items
    self:goPage(self.page)
end

return List
