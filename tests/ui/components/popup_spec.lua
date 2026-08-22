--[[--
ui.components.popup 离线用例：单选/多选、current 跳页、setListItems。

Menu/ButtonDialog/SpinWidget/CheckMark 等 KOReader 控件用最小假身，
只复刻 popup 依赖的行为（页码计算、switchItemTable 的 itemnumber 语义）。

@module tests.ui.components.popup_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
Stubs.reset()

-- —— popup 依赖的最小假身 ——

package.preload["ui.components.bookui"] = function()
    return {
        iconSz = function() return 24 end,
        sz = function(n) return n end,
        menuFontSize = function() return 22 end,
    }
end

package.preload["ui.components.image"] = function()
    return {
        widget = function(o)
            return {
                _image = o.src,
                getSize = function() return { w = o.width, h = o.height } end,
            }
        end,
    }
end

package.preload["ui.components.icon"] = function()
    return {
        widget = function(o)
            if not o.name then return nil end
            return { _icon = o.name }
        end,
    }
end

package.preload["ui/widget/checkmark"] = function()
    local CheckMark = {}
    function CheckMark:new(o)
        o = o or {}
        o._checkmark = true
        o.getSize = function() return { w = 10, h = 10 } end
        return o
    end
    return CheckMark
end

package.preload["ui/widget/horizontalgroup"] = function()
    local HorizontalGroup = {}
    function HorizontalGroup:new(o)
        o = o or {}
        o._hgroup = true
        o.getSize = function() return { w = 100, h = 20 } end
        return o
    end
    return HorizontalGroup
end

package.preload["ui/widget/verticalgroup"] = function()
    local VerticalGroup = {}
    function VerticalGroup:new(o)
        o = o or {}
        o._vgroup = true
        o.getSize = function() return { w = 100, h = 40 } end
        o.resetLayout = function() end
        return o
    end
    return VerticalGroup
end

package.preload["ui/widget/horizontalspan"] = function()
    local HorizontalSpan = {}
    function HorizontalSpan:new(o)
        o = o or {}
        o._hspan = true
        return o
    end
    return HorizontalSpan
end

package.preload["ui/widget/button"] = function()
    local Button = {}
    function Button:new(o) return o end
    return Button
end

package.preload["ui/widget/menu"] = function()
    local Menu = {}
    Menu.__index = Menu
    function Menu:new(o)
        o = o or {}
        setmetatable(o, Menu)
        o.perpage = o.items_per_page or 14
        o.item_table = o.item_table or {}
        o.page = 1
        if o.item_table.current then
            o.page = o:getPageNumber(o.item_table.current)
        end
        o._updates = 0
        o.inner_dimen = { w = 400, h = 700 }
        o.item_dimen = { w = 400, h = 50 }
        o.available_height = 600
        o.page_info_text = { setText = function() end, hide = function() end }
        o.page_info = { {}, o.page_info_text, {} } -- 假 pager 行：chev / 页码 / chev
        -- FrameContainer → OverlapGroup(content_group, page_return, footer)
        o[1] = { [1] = { {}, {}, { o.page_info } } }
        return o
    end
    function Menu:_recalculateDimen() end
    function Menu:getPageNumber(n)
        if #self.item_table == 0 or not n or n == 0 then return 1 end
        return math.ceil(math.min(n, #self.item_table) / self.perpage)
    end
    function Menu:updateItems()
        self._updates = self._updates + 1
    end
    function Menu:switchItemTable(title, items, itemnumber, _itemmatch, subtitle)
        if items then self.item_table = items end
        if title then self.title = title end
        if subtitle then self.subtitle = subtitle end
        if itemnumber == nil then
            self.page = 1
        elseif itemnumber >= 0 then
            self.page = self:getPageNumber(math.min(itemnumber, #self.item_table))
        end
        self:updateItems()
    end
    return Menu
end

package.preload["ui/widget/buttondialog"] = function()
    local ButtonDialog = {}
    function ButtonDialog:new(o) return o end
    return ButtonDialog
end

package.preload["ui/widget/spinwidget"] = function()
    local SpinWidget = {}
    function SpinWidget:new(o) return o end
    return SpinWidget
end

local UIManager = require("ui/uimanager")
local closed_widgets = {}
UIManager.close = function(_, w)
    closed_widgets[#closed_widgets + 1] = w
end

local Popup = require("ui.components.popup")

-- —— 单选：点按关闭并回传 value ——

do
    closed_widgets = {}
    local got
    local menu = Popup.list{
        title = "选择",
        items = { "甲", "乙", { text = "丙", value = 3 } },
        on_select = function(v) got = v end,
    }
    Assert.eq(#closed_widgets, 0)
    menu.item_table[2].callback()
    Assert.eq(got, "乙") -- 字符串项 value = 文本
    Assert.eq(#closed_widgets, 1) -- 单选点按后关闭
    Assert.eq(closed_widgets[1], menu)
end

-- 单选：项自带 callback 时不走 on_select
do
    closed_widgets = {}
    local fired = false
    local got
    local menu = Popup.list{
        items = {{ text = "A", value = 1, callback = function() fired = true end }},
        on_select = function(v) got = v end,
    }
    menu.item_table[1].callback()
    Assert.is_true(fired)
    Assert.is_nil(got)
end

-- —— 单选：current 跳页 ——

do
    local items = {}
    for i = 1, 40 do
        items[i] = { text = "item " .. i, value = i }
    end
    local menu = Popup.list{
        items = items,
        current = 20,
    }
    Assert.eq(menu.item_table.current, 20)
    Assert.eq(menu.page, 2) -- ceil(20/14)
    -- 无 current 时保持第 1 页
    local plain = Popup.list{ items = items }
    Assert.eq(plain.page, 1)
end

-- 单选：项上 checked=true 等价于 current
do
    local menu = Popup.list{
        items = {
            { text = "A", value = 1 },
            { text = "B", value = 2, checked = true },
        },
    }
    Assert.eq(menu.item_table.current, 2)
end

-- 禁用项：无 callback、置灰
do
    local menu = Popup.list{
        items = {{ text = "灰", enabled = false }},
    }
    local item = menu.item_table[1]
    Assert.is_nil(item.callback)
    Assert.is_true(item.dim)
end

-- —— 多选：点按切换勾选、不关闭 ——

do
    closed_widgets = {}
    local toggles = {}
    local menu = Popup.list{
        select_mode = "multi",
        items = {
            { text = "A", value = "a" },
            { text = "B", value = "b", checked = true },
            { text = "C", value = "c" },
        },
        on_toggle = function(v, checked, _item, selected)
            toggles[#toggles + 1] = { v = v, checked = checked, n = #selected }
        end,
    }
    -- 初始勾选体现在 Material 图标上
    Assert.eq(menu.item_table[2].state._icon, "check_box")
    Assert.eq(menu.item_table[1].state._icon, "check_box_outline_blank")

    local before = menu._updates
    menu.item_table[1].callback() -- 勾上 A
    Assert.eq(#closed_widgets, 0) -- 多选不关闭
    Assert.eq(menu._updates, before + 1) -- 重绘当前页
    Assert.eq(menu.item_table[1].state._icon, "check_box")
    Assert.eq(toggles[1].v, "a")
    Assert.is_true(toggles[1].checked)
    Assert.eq(toggles[1].n, 2) -- a + 初始的 b

    menu.item_table[1].callback() -- 再点取消
    Assert.eq(menu.item_table[1].state._icon, "check_box_outline_blank")
    Assert.eq(toggles[2].n, 1)
end

-- 多选：禁用项不可切换，勾选框同样禁用
do
    local menu = Popup.list{
        select_mode = "multi",
        items = {{ text = "锁", value = "x", enabled = false, checked = true }},
    }
    local item = menu.item_table[1]
    Assert.is_nil(item.callback)
    Assert.eq(item.state._icon, "check_box")
end

-- 多选 + 图标：勾选框与图标并存（HorizontalGroup 组合）
do
    local menu = Popup.list{
        select_mode = "multi",
        items = {{ text = "带图标", value = 1, icon = "home", checked = true }},
    }
    local state = menu.item_table[1].state
    Assert.is_true(state._hgroup)
    Assert.eq(state[1]._icon, "check_box")
    Assert.is_true(state[3]._icon == "home")
    Assert.eq(menu.state_w, 24 + 6 + 24) -- Material 选择图标 + 间距 + 图标
end

-- —— setListItems：更新内容不关闭，current 跳页 ——

do
    local menu = Popup.list{ title = "旧", items = { "占位" } }
    local items = {}
    for i = 1, 30 do
        items[i] = { text = "v" .. i, value = i }
    end
    Popup.setListItems(menu, "新标题", items, nil, { current = 25 })
    Assert.eq(menu.title, "新标题")
    Assert.eq(#menu.item_table, 30)
    Assert.eq(menu.page, 2) -- ceil(25/14)
    Assert.eq(menu.item_table.current, 25)

    -- 不带 current：回到第 1 页（既有行为）
    Popup.setListItems(menu, nil, { "x" })
    Assert.eq(menu.page, 1)
    Assert.eq(menu.title, "新标题") -- title 为 nil 时保留
end

-- setListItems：menu 为 nil 时静默返回
Popup.setListItems(nil, "t", { "x" })

-- —— bottom_tabs：完整 pager 之下的独立 Tab 栏 ——

do
    local active
    local menu = Popup.list{
        items = { "a", "b" },
        bottom_tabs = {
            tabs = { { id = "x", text = "X" }, { id = "y", text = "Y" }, { id = "z", text = "Z" } },
            active = "x",
            on_tab = function(id) active = id end,
        },
    }
    -- footer 子件换成竖排：pager 原样在上，Tab 栏在下
    local stack = menu[1][1][3][1]
    Assert.eq(stack[1], menu.page_info)
    local bar = stack[2]
    Assert.eq(#bar, 3)
    Assert.eq(bar[1].width, 133) -- floor(400/3)，全宽等分
    Assert.is_true(bar[1].text_font_bold) -- 当前 Tab 加粗
    Assert.is_true(bar[2].text_font_bold == false)
    Assert.is_true(menu._updates >= 1) -- 挂载后触发全量重算
    bar[1].callback() -- 点当前 Tab：不触发
    Assert.is_nil(active)
    bar[2].callback()
    Assert.eq(active, "y")
    menu:setBottomTabActive("y")
    local bar2 = menu[1][1][3][1][2]
    Assert.is_true(bar2[2].text_font_bold)
    Assert.is_true(bar2[1].text_font_bold == false)
end

-- —— sheet / spin 回归 ——

do
    local got
    local dialog = Popup.sheet{
        title = "动作",
        items = {
            { text = "一", value = 1 },
            { separator = true }, -- 分隔被跳过
            "二",
        },
        on_select = function(v) got = v end,
    }
    Assert.eq(#dialog.buttons, 2)
    dialog.buttons[2][1].callback()
    Assert.eq(got, "二")

    local spin = Popup.spin{ title = "字号", value = 5, value_min = 1, value_max = 10 }
    Assert.eq(spin.value, 5)
    Assert.eq(spin.value_max, 10)
end
