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
  |  [分栏一]  [分栏二]  [分栏三] |   tabs 给了才有（仅全屏）
  +-------------------------------+

subtitle 只在全屏标题栏里显示；居中面板点外面关，全屏点右上角或返回键关；左右滑翻页。
居中面板可给 anchor 矩形（贴着按钮弹出，每页行数按锚点上下较大一侧的空间算）与 inner_width（内容宽上限，物理像素）。
左上角按钮：left_icon + left_callback（仅全屏）。
items：{ text, value, icon, mandatory（右侧状态字）, widget（右侧控件，优先于 mandatory；
         可给函数，翻到该页才构建）, image / image_w / image_h（缩略图，逻辑像素）,
         enabled, checked, callback, keep_open, chevron（画右箭头，如进入子菜单） }
  checked 为 nil 的项不画选择标记；非 nil 时单选画 radio、多选画 checkbox。
  callback：单选时代替 on_select 调 callback()；多选时先 callback(checked, item) 再 on_toggle。
单选：点按即关窗（keep_open 的项不关），再 callback() 或 on_select(value, item)；
      打开时翻到第一个 checked 项所在页，该项按选中样式画。
      给了 current 时不看 checked：value == current 的项选中，每项都画 radio（不改调用方的 items）。
多选：点按就地翻转 item.checked（会改调用方的 items）并 on_toggle(value, checked, item)，不关窗；
      结果在 close_callback 里读 items。
分栏：tabs = { tabs = { { id, text, icon } }, active = id, on_tab = fun(id): items }；
      切栏时 on_tab 返回新项，翻到其 checked 项所在页。

  List:new{ title = "排序", items = items, on_select = fn }:show()
  list:setItems(items)   -- 异步加载后替换内容，停留在原页（越界则夹到末页）

@module koplugin.book.ui.themes.widgets.list
--]]

local BD = require("ui/bidi")
local GestureRange = require("ui/gesturerange")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Theme = require("ui.themes")
local Box = require("ui.themes.widgets.box")
local Modal = require("ui.themes.widgets.modal")
local Pager = require("ui.themes.widgets.pager")
local Row = require("ui.themes.widgets.row")
local Tabbar = require("ui.themes.widgets.tabbar")
local TitleBar = require("ui.themes.widgets.titlebar")

---@class BookThemeListTabs
---@field tabs table[] { id, text, icon }
---@field active any
---@field on_tab fun(id: any): table[]

---@class BookThemeList : BookThemeModal
---@field title string|nil
---@field subtitle string|nil
---@field items table[]
---@field multi boolean
---@field centered boolean
---@field left_icon string|nil
---@field left_callback fun()|nil
---@field tabs BookThemeListTabs|nil
---@field current any 单选当前值；非 nil 时代替各项 checked
---@field inner_width number|nil 居中面板内容宽上限（物理像素）；缺省标准弹窗宽
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
    left_icon = nil,
    left_callback = nil,
    tabs = nil,
    current = nil,
    on_select = nil,
    on_toggle = nil,
}

function List:init()
    self.covers_fullscreen = not self.centered
    Modal.init(self)
    local t = self.theme
    local pad = Theme.px(t.space.lg)
    self.row_w = self.centered and self:innerWidth() or self.dimen.w
    self.pitch = Row.height(false) + Theme.px(t.row.divider)
    local chrome = Theme.px(t.control.height)                      -- 翻页条
        + (self.centered and pad * 4 + Theme.px(t.font.title * 2)   -- 面板边距 + 标题
            or TitleBar.height() + (self.tabs and Tabbar.height() or 0))
    local room = self.dimen.h
    local a = self.anchor
    if type(a) == "table" then
        room = math.max(a.y, self.dimen.h - a.y - a.h) - Theme.px(t.space.sm) * 2
    end
    self.per_page = math.max(1, math.floor((room - chrome) / self.pitch))
    self.page = self:checkedPage()
    self.ges_events.SwipeList = { GestureRange:new{ ges = "swipe", range = self.dimen } }
    self:rebuild()
end

--- 居中面板内容宽：标准弹窗宽，给了 inner_width 时取较小者。
---@return number 物理像素
function List:innerWidth()
    return math.min(self.inner_width or math.huge, Modal.innerWidth(self))
end

---@param _arg any
---@param ges table
---@return boolean
function List:onSwipeList(_arg, ges)
    local dir = BD.flipDirectionIfMirroredUILayout(ges.direction)
    if dir == "west" then
        self:goPage(self.page + 1)
    elseif dir == "east" then
        self:goPage(self.page - 1)
    else
        return false
    end
    return true
end

--- 重画：嵌在别的窗口里时刷所在窗口。
--- 居中面板变矮时连底下窗口一起重画：网纹遮罩不盖底，只刷自己会把旧面板留在新面板外面。
function List:refresh()
    local old_h = self[1] and self[1]:getSize().h
    self:rebuild()
    local shrunk = self.centered and old_h and self[1]:getSize().h < old_h
    UIManager:setDirty(shrunk and "all" or self.show_parent or self, "ui")
end

---@return integer
function List:pages()
    return math.max(1, math.ceil(#self.items / self.per_page))
end

--- 项的选中态：给了 current 按值比，否则取 item.checked（nil 表示不画标记）。
---@param item table
---@return boolean|nil
function List:checked(item)
    if self.current ~= nil then return item.value == self.current end
    return item.checked
end

--- 第一个选中项所在页；没有则第 1 页。
---@return integer
function List:checkedPage()
    for i, item in ipairs(self.items) do
        if self:checked(item) then return math.ceil(i / self.per_page) end
    end
    return 1
end

--- 选择标记图标；未参与选择的项用自己的 icon。
---@param item table
---@return string|nil
function List:markIcon(item)
    local checked = self:checked(item)
    if checked == nil then return item.icon end
    if self.multi then return checked and "check_box" or "check_box_outline_blank" end
    return checked and "radio_button_checked" or "radio_button_unchecked"
end

---@param item table
function List:choose(item)
    if self.multi then
        item.checked = not item.checked
        if item.callback then item.callback(item.checked, item) end
        if self.on_toggle then self.on_toggle(item.value, item.checked, item) end
        self:refresh()
        return
    end
    if not item.keep_open then self:close() end
    if item.callback then
        item.callback()
    elseif self.on_select then
        self.on_select(item.value, item)
    end
end

--- 按当前页重建面板。
function List:rebuild()
    local t = self.theme
    local pages = self:pages()
    local rows = VerticalGroup:new{ align = "left" }
    local first = (self.page - 1) * self.per_page
    for i = first + 1, math.min(#self.items, first + self.per_page) do
        local item = self.items[i]
        local status = item.widget
        if type(status) == "function" then status = status() end
        rows[#rows + 1] = Row.widget({
            width = self.row_w,
            icon = self:markIcon(item),
            image = item.image,
            image_w = item.image_w,
            image_h = item.image_h,
            title = item.text,
            status = status or item.mandatory,
            chevron = item.chevron == true,
            selected = not self.multi and self:checked(item) == true,
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
        if pager then
            -- 末页不满也补成整页高，翻页时面板和翻页条不跳位置。
            local missing = first + self.per_page - math.min(#self.items, first + self.per_page)
            body[#body + 1] = VerticalSpan:new{ width = missing * self.pitch }
            body[#body + 1] = pager
        end
        self:setDialog{ title = self.title, body = body }
        return
    end
    -- 全屏：翻页条和分栏钉在底部，行不满一页时中间补空。
    local bar = TitleBar.widget({
        width = self.row_w, title = self.title, subtitle = self.subtitle,
        left_icon = self.left_icon, left_callback = self.left_callback,
        right_icon = "close", right_callback = function() self:dismiss() end,
    })
    local tabbar = self.tabs and Tabbar.widget({
        width = self.row_w,
        tabs = self.tabs.tabs,
        active = self.tabs.active,
        on_tab = function(id) self:switchTab(id) end,
    })
    local used = bar:getSize().h + rows:getSize().h
        + (pager and pager:getSize().h or 0) + (tabbar and tabbar:getSize().h or 0)
    local page = VerticalGroup:new{
        align = "left",
        bar,
        rows,
        VerticalSpan:new{ width = math.max(0, self.dimen.h - used) },
    }
    if pager then page[#page + 1] = pager end
    if tabbar then page[#page + 1] = tabbar end
    self:setPanel(Box:new{ style = { bg = t.color.page }, width = self.dimen.w, height = self.dimen.h, page })
end

---@param page integer
function List:goPage(page)
    self.page = math.max(1, math.min(self:pages(), page))
    self:refresh()
end

--- 替换全部项，停在原页（越界夹到末页）。
---@param items table[]
function List:setItems(items)
    self.items = items
    self:goPage(self.page)
end

--- 切分栏：换成 on_tab 返回的项，翻到其 checked 项所在页。
---@param id any
function List:switchTab(id)
    self.tabs.active = id
    self.items = self.tabs.on_tab(id)
    self:goPage(self:checkedPage())
end

return List
