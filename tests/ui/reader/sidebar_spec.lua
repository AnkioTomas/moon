--[[--
ui.reader.sidebar 离线用例：右滑入口（edge / full / off 与起手位置）、触摸区覆盖原生翻页、
X-Ray 开关决定页数、借用原生菜单（尺寸压进侧栏、改挂 show_parent、关闭链路与原生清理、
全局 Menu 缺省值 / UIManager.show 还原）、点遮罩关闭。

@module tests.ui.reader.sidebar_spec
--]]

local Assert = require("support.assert")

local state = {
    reader = {},
    snapshot = nil,
    shown = {},
    closed = {},
    dirty = 0,
    opened = {},
    native_closed = {},
    tickets = {},
    ticks = {},
}
local function flush()
    local ticks = state.ticks
    state.ticks = {}
    for _, fn in ipairs(ticks) do fn() end
end

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(s) return s end end
package.preload["device"] = function()
    return {
        hasKeys = function() return false end,
        screen = {
            getSize = function() return { w = 600, h = 800 } end,
            getWidth = function() return 600 end,
        },
    }
end
package.preload["ffi/blitbuffer"] = function()
    return { COLOR_WHITE = 255, COLOR_BLACK = 0, COLOR_LIGHT_GRAY = 170 }
end
package.preload["ui/geometry"] = function() return { new = function(_, o) return o end } end
local function plain() return { new = function(_, o) return o or {} end } end
for _, name in ipairs({
    "ui/gesturerange", "ui/widget/container/framecontainer", "ui/widget/horizontalgroup",
    "ui/widget/linewidget", "ui/widget/overlapgroup", "ui/widget/verticalgroup",
}) do
    package.preload[name] = plain
end
package.preload["ui/widget/container/inputcontainer"] = function()
    local IC = {}
    IC.__index = IC
    function IC:extend(sub)
        sub = sub or {}
        sub.__index = sub
        return setmetatable(sub, self)
    end
    function IC:new(o)
        o = setmetatable(o or {}, self)
        if o.init then o:init() end
        return o
    end
    return IC
end

-- 与真身同契约：实例缺宽高时回落到类缺省值；页脚 = 4 个共享间隔 + 页码 + 4 个箭头。
local function part(w)
    return { w = w, shown = true, showHide = function(self, on) self.shown = on end }
end
local Menu = {}
Menu.__index = Menu
function Menu:new(o)
    o = setmetatable(o or {}, self)
    o.w, o.h = o.width, o.height
    o.inner_dimen = { w = o.width, h = o.height }
    o.item_table = o.item_table or {}
    o.page_num = o.page_num or 1
    o.page_info_spacer = { width = 32 }
    o.page_info_text = part(200)
    o.page_info_text.text = "第 1 页，共 1 页"
    o.page_info_text.setText = function(self, text) self.text = text end
    o.page_info_left_chev, o.page_info_right_chev = part(40), part(40)
    o.page_info_first_chev, o.page_info_last_chev = part(40), part(40)
    local menu = o
    o.page_info = {
        resetLayout = function() end,
        getSize = function() return { w = 200 + 4 * 40 + 4 * menu.page_info_spacer.width } end,
    }
    return o
end
function Menu:updatePageInfo() self.page_info_updates = (self.page_info_updates or 0) + 1 end
package.loaded["ui/widget/menu"] = Menu

local UIManager = {
    show = function(_, w) state.shown[#state.shown + 1] = w end,
    close = function(_, w)
        state.closed[#state.closed + 1] = w
        if w.onCloseWidget then w:onCloseWidget() end
    end,
    setDirty = function() state.dirty = state.dirty + 1 end,
    nextTick = function(_, fn) state.ticks[#state.ticks + 1] = fn end,
}
package.loaded["ui/uimanager"] = UIManager
local original_show = UIManager.show

package.preload["ui.components.meshmask"] = function()
    return { widget = function() return { mesh = true } end }
end
package.preload["ui.components.pagestrip"] = function()
    return {
        bandH = function() return 40 end,
        widget = function(o) return { strip = o } end,
    }
end
package.preload["ui.components.bookui"] = function()
    return {
        pagePad = function() return 10 end,
        line = function() return 1 end,
    }
end
package.preload["utils.settings"] = function()
    return { get = function() return state.reader end }
end
package.preload["ui.reader.session"] = function()
    return { current = function() return state.snapshot end }
end
package.preload["ui.reader.sidebar.info"] = function()
    return { build = function(_, w, h, _, on_exit)
        state.on_exit = on_exit
        return { info = true, w = w, h = h }
    end }
end
package.preload["ui.panel.native"] = function()
    return { closeToDesktop = function(ui) state.exited = ui end }
end
--- 票根：出图回调由测试手动触发，模拟封面异步落定。
package.preload["ui.reader.sidebar.ticket"] = function()
    return { new = function(snapshot, on_ready)
        local ticket = { snapshot = snapshot, ready = false, on_ready = on_ready }
        function ticket:widget(w, h) return { ticket = self, ready = self.ready, w = w, h = h } end
        function ticket:cancel() self.cancelled = true end
        state.tickets[#state.tickets + 1] = ticket
        return ticket
    end }
end

--- 原生目录：Menu 套在全屏 CenterContainer 里再 show；带状态清理的 close_callback。
package.preload["ui.panel.actions.reader.toc"] = function()
    return { run = function(ctx)
        state.opened[#state.opened + 1] = "toc"
        local container = {}
        local menu = Menu:new{ title = "目录", item_table = { { text = "第一章" } } }
        menu.show_parent = container
        menu.close_callback = function() state.native_closed[#state.native_closed + 1] = "toc" end
        container[1] = menu
        ctx.ui.toc_menu = menu
        UIManager:show(container)
    end }
end
package.preload["xray.ui"] = function()
    return { openMain = function()
        state.opened[#state.opened + 1] = "xray"
        UIManager:show({ info_message = true })
    end }
end

local Sidebar = require("ui.reader.sidebar")

local ui = {}
function ui:registerTouchZones(zones) self.zones = zones end
ui.bookmark = {
    onShowBookmark = function()
        state.opened[#state.opened + 1] = "notes"
        local menu = Menu:new{ title = "书签" }
        menu.close_callback = function() state.native_closed[#state.native_closed + 1] = "notes" end
        UIManager:show(menu)
    end,
}

-- 触摸区：全屏 swipe，覆盖原生翻页；重复 install 只注册一次。
Sidebar.install(ui)
Assert.len(ui.zones, 1)
local zone = ui.zones[1]
Assert.eq(zone.ges, "swipe")
Assert.contains(zone.overrides, "paging_swipe")
Assert.contains(zone.overrides, "rolling_swipe")
ui.zones = nil
Sidebar.install(ui)
Assert.is_nil(ui.zones)

local function swipe(direction, x)
    return zone.handler({ direction = direction, pos = { x = x, y = 300 } })
end

-- 没有阅读会话：不接手，交还原生翻页。
Assert.is_false(swipe("east", 10))
Assert.len(state.shown, 0)

state.snapshot = { identity = { source_id = "local", stable_id = "/b.epub" } }

-- 缺省 edge：只认左缘（15% 屏宽内）起手的右滑；其他方向一律放行。
Assert.is_false(swipe("west", 10))
Assert.is_false(swipe("east", 200), "中间右滑仍是原生上一页")
Assert.is_true(swipe("east", 60))
Assert.len(state.shown, 1)

state.reader = { sidebar_gesture = "full" }
Assert.is_true(swipe("east", 500))
Assert.len(state.shown, 2)

state.reader = { sidebar_gesture = "off" }
Assert.is_false(swipe("east", 10))
Assert.len(state.shown, 2)

-- X-Ray 关闭时少一页；票根永远在最后。
state.reader = { book_xray_enabled = false }
Assert.eq(table.concat(Sidebar:new{ ui = ui, snapshot = state.snapshot }.tabs, ","), "info,toc,notes,ticket")
state.reader = {}

local bar = state.shown[1]
Assert.eq(table.concat(bar.tabs, ","), "info,toc,notes,xray,ticket")
Assert.eq(bar.panel_w, 510)
Assert.is_true(bar[1][1].mesh, "底层是网状遮罩")
local info_box = bar[1][2][1][1][1]
Assert.eq(info_box.dimen.w, 490, "书籍页内容区定宽 = 面板宽 - 两侧内边距")
Assert.eq(info_box.dimen.h, 800 - 40 - 1 - 20, "内容区定高，底栏才能贴底")
Assert.len(state.opened, 0, "列表页没打开前不借菜单")

-- 面板内点空白不关；点遮罩关。
Assert.is_true(bar:onTapSidebar(nil, { pos = { x = 100, y = 10 } }))
Assert.len(state.closed, 0)

-- 左滑到目录：借原生目录 Menu，尺寸 = 面板宽 × (屏高 - 底栏 - 分隔线)，不弹全屏容器。
local dirty = state.dirty
bar:onSwipeSidebar(nil, { direction = "west", pos = { x = 100, y = 10 } })
Assert.eq(bar.tab, 2)
Assert.eq(state.dirty, dirty + 1)
Assert.len(state.shown, 2, "原生全屏容器被截下，不上屏")
local toc_menu = bar[1][2][1][1][1]
Assert.eq(toc_menu, ui.toc_menu)
Assert.eq(toc_menu.w, 510)
Assert.eq(toc_menu.h, 800 - 40 - 1)
Assert.eq(toc_menu.show_parent, bar, "刷新改挂到侧栏窗口")
Assert.is_nil(Menu.width, "Menu 缺省宽高已还原")
Assert.eq(UIManager.show, original_show, "UIManager.show 已还原")

-- 页脚：单页整行藏起；多页时 200 + 160 + 4×32 = 488 ≤ 510 保持原间隔。
Assert.eq(toc_menu.page_info_text.text, "", "文字按钮 hide 无效，单页清空页码")
Assert.is_false(toc_menu.page_info_left_chev.shown)
toc_menu.page_num = 3
toc_menu:updatePageInfo()
Assert.eq(toc_menu.page_info_updates, 1, "原生 updatePageInfo 照常执行")
Assert.is_true(toc_menu.page_info_left_chev.shown, "变成多页后页脚恢复")
Assert.eq(toc_menu.page_info_spacer.width, 32)
-- 页码文案变长（放不下）：四个间隔等量收窄到刚好放下。
toc_menu.page_info_text.w = 260
toc_menu.page_info.getSize = function()
    return { w = 260 + 160 + 4 * toc_menu.page_info_spacer.width }
end
toc_menu:updatePageInfo()
Assert.eq(toc_menu.page_info_spacer.width, 22, "548 - 510 = 38，每个间隔收 ceil(38/4) = 10")

-- 切走再切回复用同一个菜单（折叠状态保留），不重复打开。
bar:goTab(1)
bar:goTab(2)
Assert.len(state.opened, 1)
Assert.eq(bar[1][2][1][1][1], toc_menu)

-- 书摘：原生书签列表直接 show 的 Menu 同样被借入。
bar:goTab(3)
local notes_menu = bar[1][2][1][1][1]
Assert.eq(notes_menu.title, "书签")
Assert.eq(notes_menu.w, 510)

-- X-Ray 入口只弹了提示（非 Menu）：照常显示，页内给白底占位。
bar:goTab(4)
Assert.is_true(state.shown[#state.shown].info_message)
Assert.eq(bar[1][2][1][1][1].height, 800 - 40 - 1)
bar:goTab(4)

-- 票根：首次进入才生成；未出图先显示占位，出图回调推迟一 tick 再刷新本页。
Assert.len(state.tickets, 0, "没进票根页不生成")
bar:goTab(5)
Assert.len(state.tickets, 1)
local ticket = state.tickets[1]
Assert.eq(ticket.snapshot, state.snapshot)
local ticket_body = bar[1][2][1][1][1][1]
Assert.is_false(ticket_body.ready)
Assert.eq(ticket_body.w, 510)
Assert.eq(ticket_body.h, 800 - 40 - 1)
ticket.ready = true
dirty = state.dirty
ticket.on_ready()
Assert.eq(state.dirty, dirty, "回调里不直接重绘（可能在 render 内同步回调）")
flush()
Assert.is_true(bar[1][2][1][1][1][1].ready)
Assert.eq(state.dirty, dirty + 1)
-- 切走再回来复用同一张；切走后才出图的回调不重绘别的页。
bar:goTab(4)
bar:goTab(5)
Assert.len(state.tickets, 1)
bar:goTab(1)
dirty = state.dirty
ticket.on_ready()
flush()
Assert.eq(state.dirty, dirty)

-- 菜单内选中条目会调 close_callback：关侧栏，并补跑所有借来菜单的原生清理（各一次）。
toc_menu.close_callback()
Assert.eq(state.closed[#state.closed], bar)
Assert.len(state.native_closed, 2)
Assert.contains(state.native_closed, "notes")
Assert.is_true(ticket.cancelled, "关侧栏取消票根任务")
Assert.is_nil(bar.ticket)
bar:onClose()
Assert.len(state.native_closed, 2, "重复关闭不重复清理")

-- 书籍页右上角关闭：先关侧栏，再关书回桌面。
local exiting = Sidebar:new{ ui = ui, snapshot = state.snapshot }
state.on_exit()
Assert.eq(state.closed[#state.closed], exiting)
Assert.eq(state.exited, ui)

-- open() 抛错：全局照样还原，错误原样上抛。
package.loaded["ui.panel.actions.reader.toc"] = { run = function() error("boom", 0) end }
local fresh = Sidebar:new{ ui = ui, snapshot = state.snapshot }
Assert.errors(function() fresh:goTab(2) end)
Assert.is_nil(Menu.width)
Assert.eq(UIManager.show, original_show)

-- 书籍页左滑切页；遮罩上滑动直接关闭。
local other = Sidebar:new{ ui = ui, snapshot = state.snapshot }
other:onSwipeSidebar(nil, { direction = "west", pos = { x = 580, y = 10 } })
Assert.eq(state.closed[#state.closed], other)
Assert.eq(other.tab, 1)

return true
