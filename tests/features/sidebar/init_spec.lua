--[[--
features.sidebar.init 离线用例：右滑入口（edge / full / off 与起手位置）、触摸区覆盖原生翻页、
X-Ray 开关决定页数、借用原生菜单（尺寸压进侧栏、改挂 show_parent、关闭链路与原生清理、
全局 Menu 缺省值 / UIManager.show 还原）、点遮罩关闭。

@module tests.features.sidebar.init_spec
--]]

local Assert = require("support.assert")

local state = {
    sidebar = { sidebar_gesture = "edge", sidebar_hidden_tabs = {}, sidebar_tab_order = {} },
    xray = { book_xray_enabled = true },
    snapshot = nil,
    shown = {},
    closed = {},
    dirty = 0,
    opened = {},
    native_closed = {},
    tickets = {},
    font_jobs = {},
    ticks = {},
}
local function flush()
    local ticks = state.ticks
    state.ticks = {}
    for _, fn in ipairs(ticks) do fn() end
end

package.loaded["features.sidebar.stats"] = { available = function() return false end }
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
    return {
        COLOR_WHITE = 255, COLOR_BLACK = 0, COLOR_LIGHT_GRAY = 170,
        Color8 = function(c) return c end,
    }
end
package.preload["ui/geometry"] = function() return { new = function(_, o) return o end } end
local function plain() return { new = function(_, o) return o or {} end } end
for _, name in ipairs({
    "ui/gesturerange", "ui/widget/horizontalgroup", "ui/widget/horizontalspan", "ui/widget/verticalspan",
    "ui/widget/linewidget", "ui/widget/overlapgroup", "ui/widget/verticalgroup", "ui.themes.widgets.box",
}) do
    package.preload[name] = plain
end
require("support.modal_stub").install()

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

package.preload["ui.themes"] = function()
    return {
        px = function(n) return n end,
        current = function()
            return {
                control = { height = 40 },
                space = { lg = 16 },
                row = { divider = 1 },
                color = { rule = 1, ink = 0, page = 255, muted = 2 },
            }
        end,
    }
end
package.preload["ui.themes.widgets.text"] = function()
    return { line = function(_, text) return { muted = text } end }
end
package.preload["ui.themes.widgets.icon"] = function()
    return { new = function(_, o) return o or {} end, getSize = function() return { w = 0, h = 0 } end }
end
package.preload["ui.themes.widgets.mask"] = function()
    return { new = function(_, opts) return { mesh = true, dimen = opts.dimen } end }
end
package.preload["ui.themes.widgets.tabbar"] = function()
    return {
        height = function() return 41 end,
        widget = function(o) return { strip = o } end,
    }
end
package.preload["utils.settings"] = function()
    return { get = function(owner) return state[owner:match("[^.]+$")] end }
end
package.preload["reader.session"] = function()
    return { current = function() return state.snapshot end }
end
package.preload["features.sidebar.info"] = function()
    return { build = function(_, w, h, _, on_exit)
        state.on_exit = on_exit
        return { info = true, w = w, h = h }
    end }
end
--- 字体：listAsync 的回调由测试手动触发，模拟子进程扫盘 / 网络异步返回。
package.preload["ui.fonts.reader"] = function()
    return { supports = function(ui) return ui.font ~= nil end }
end
package.preload["ui.fonts.catalog"] = function()
    return {
        listAsync = function(cb)
            local job = { cb = cb }
            job.cancel = function() job.cancelled = true end
            state.font_jobs[#state.font_jobs + 1] = job
            return job
        end,
    }
end
package.preload["features.panel.actions.reader.font"] = function()
    return { pickerOpts = function(ui) return { ui = ui } end }
end
--- 主题 List：只模拟缺省宽高（borrowMenu 临时改写）与 show。
local ThemeList = {}
package.preload["ui.themes.widgets.list"] = function() return ThemeList end
package.preload["ui.widgets.fontpicker"] = function()
    return { show = function(opts, items)
        local list = { title = "阅读字体", items = items, w = ThemeList.width, h = ThemeList.height, picker_opts = opts }
        list.close_callback = function() state.native_closed[#state.native_closed + 1] = "font" end
        UIManager:show(list)
    end }
end
package.preload["features.panel.native"] = function()
    return { closeToDesktop = function(ui) state.exited = ui end }
end
--- 票根：出图回调由测试手动触发，模拟封面异步落定。
package.preload["features.sidebar.ticket"] = function()
    return { new = function(snapshot, on_ready)
        local ticket = { snapshot = snapshot, ready = false, on_ready = on_ready }
        function ticket:widget(w, h) return { ticket = self, ready = self.ready, w = w, h = h } end
        function ticket:cancel() self.cancelled = true end
        state.tickets[#state.tickets + 1] = ticket
        return ticket
    end }
end

--- 原生目录：Menu 套在全屏 CenterContainer 里再 show；带状态清理的 close_callback。
package.preload["features.panel.actions.reader.toc"] = function()
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
package.preload["features.xray.ui"] = function()
    return { openMain = function()
        state.opened[#state.opened + 1] = "xray"
        UIManager:show({ info_message = true })
    end }
end

local Sidebar = require("features.sidebar")

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

state.sidebar = { sidebar_gesture = "full", sidebar_hidden_tabs = {}, sidebar_tab_order = {} }
Assert.is_true(swipe("east", 500))
Assert.len(state.shown, 2)

state.sidebar = { sidebar_gesture = "off", sidebar_hidden_tabs = {}, sidebar_tab_order = {} }
Assert.is_false(swipe("east", 10))
Assert.len(state.shown, 2)

-- X-Ray 关闭时少一页；票根永远在最后。
state.xray = { book_xray_enabled = false }
Assert.eq(table.concat(Sidebar:new{ ui = ui, snapshot = state.snapshot }.tabs, ","), "info,toc,notes,ticket")
state.xray = { book_xray_enabled = true }

local bar = state.shown[1]
Assert.eq(table.concat(bar.tabs, ","), "info,toc,notes,xray,ticket")
Assert.eq(bar.panel_w, 510)
Assert.is_true(bar.mask ~= false, "用 Modal 的整屏遮罩")
Assert.eq(bar.panel_x, 0, "面板贴左缘")
local info_box = bar[1][1][1][1]
Assert.eq(info_box.dimen.w, 510 - 16 * 2, "书籍页内容区定宽 = 面板宽 - 两侧内边距")
Assert.eq(info_box.dimen.h, 800 - 40 - 1 - 16 * 2, "内容区定高，底栏才能贴底")
Assert.len(state.opened, 0, "列表页没打开前不借菜单")

-- 面板内点空白不关；点遮罩关。
Assert.is_true(bar:onTapModal(nil, { pos = { x = 100, y = 10 } }))
Assert.len(state.closed, 0)

-- 左滑到目录：借原生目录 Menu，尺寸 = 面板宽 × (屏高 - 底栏 - 分隔线)，不弹全屏容器。
local dirty = state.dirty
bar:onSwipeSidebar(nil, { direction = "west", pos = { x = 100, y = 10 } })
Assert.eq(bar.tab, 2)
Assert.eq(state.dirty, dirty + 1)
Assert.len(state.shown, 2, "原生全屏容器被截下，不上屏")
local toc_menu = bar[1][1][1][1]
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
Assert.eq(bar[1][1][1][1], toc_menu)

-- 书摘：原生书签列表直接 show 的 Menu 同样被借入。
bar:goTab(3)
local notes_menu = bar[1][1][1][1]
Assert.eq(notes_menu.title, "书签")
Assert.eq(notes_menu.w, 510)

-- X-Ray 入口只弹了提示（非 Menu）：照常显示，页内给白底占位。
bar:goTab(4)
Assert.is_true(state.shown[#state.shown].info_message)
Assert.eq(bar[1][1][1][1].height, 800 - 40 - 1)
bar:goTab(4)

-- 票根：首次进入才生成；未出图先显示占位，出图回调推迟一 tick 再刷新本页。
Assert.len(state.tickets, 0, "没进票根页不生成")
bar:goTab(5)
Assert.len(state.tickets, 1)
local ticket = state.tickets[1]
Assert.eq(ticket.snapshot, state.snapshot)
local ticket_body = bar[1][1][1][1][1]
Assert.is_false(ticket_body.ready)
Assert.eq(ticket_body.w, 510)
Assert.eq(ticket_body.h, 800 - 40 - 1)
ticket.ready = true
dirty = state.dirty
ticket.on_ready()
Assert.eq(state.dirty, dirty, "回调里不直接重绘（可能在 render 内同步回调）")
flush()
Assert.is_true(bar[1][1][1][1][1].ready)
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
package.loaded["features.panel.actions.reader.toc"] = { run = function() error("boom", 0) end }
local fresh = Sidebar:new{ ui = ui, snapshot = state.snapshot }
Assert.errors(function() fresh:goTab(2) end)
Assert.is_nil(Menu.width)
Assert.eq(UIManager.show, original_show)

-- 阅读字体：文档支持换字体才有这一页，排在目录后。
local font_ui = { font = {}, bookmark = ui.bookmark }
local fonted = Sidebar:new{ ui = font_ui, snapshot = state.snapshot }
Assert.eq(table.concat(fonted.tabs, ","), "info,toc,font,notes,xray,ticket")
Assert.len(state.font_jobs, 0, "没进字体页不拉列表")
fonted:goTab(3)
Assert.len(state.font_jobs, 1)
local loading = fonted[1][1][1][1]
Assert.eq(loading[1].muted, "正在加载字体列表…")
-- 列表回来：借选择器菜单进侧栏，推迟一 tick 重画；选择器参数来自阅读字体快捷动作。
local shown_before = #state.shown
state.font_jobs[1].cb({ { id = "a" } })
Assert.len(state.shown, shown_before, "选择器菜单被截下，不上屏")
flush()
local font_menu = fonted[1][1][1][1]
Assert.eq(font_menu.title, "阅读字体")
Assert.eq(font_menu.w, 510)
Assert.eq(font_menu.picker_opts.ui, font_ui)
Assert.eq(font_menu.show_parent, fonted)
Assert.is_nil(ThemeList.width, "List 缺省宽高已还原")
-- 选中字体后 List 自关：关侧栏，补跑选择器原 close_callback。
font_menu:close()
Assert.eq(state.closed[#state.closed], fonted)
Assert.contains(state.native_closed, "font")

-- 列表加载失败：给文案，不重试；关侧栏时取消还在拉的列表。
local failing = Sidebar:new{ ui = font_ui, snapshot = state.snapshot }
failing:goTab(3)
state.font_jobs[2].cb(nil)
flush()
Assert.eq(failing[1][1][1][1][1].muted, "字体列表加载失败")
local pending = Sidebar:new{ ui = font_ui, snapshot = state.snapshot }
pending:goTab(3)
pending:onClose()
Assert.is_true(state.font_jobs[3].cancelled)
Assert.is_nil(pending.font_job)

-- 书籍页左滑切页；遮罩上滑动直接关闭。
local other = Sidebar:new{ ui = ui, snapshot = state.snapshot }
other:onSwipeSidebar(nil, { direction = "west", pos = { x = 580, y = 10 } })
Assert.eq(state.closed[#state.closed], other)
Assert.eq(other.tab, 1)

-- 底栏图标：每页一格、当前页高亮，点哪格直达哪页，不经过中间页。
do
    local jump = Sidebar:new{ ui = ui, snapshot = state.snapshot }
    local strip = jump[1][1][2][1].strip
    Assert.eq(strip.width, 510)
    Assert.eq(strip.active, "info")
    Assert.len(strip.tabs, 5)
    Assert.eq(strip.tabs[5].id, "ticket")
    Assert.eq(strip.tabs[5].icon, "confirmation_number")
    local opened, tickets = #state.opened, #state.tickets
    strip.on_tab("ticket")
    Assert.eq(jump.tab, 5)
    Assert.len(state.opened, opened, "跳过目录 / 书摘，不借它们的菜单")
    Assert.len(state.tickets, tickets + 1)
    Assert.eq(jump[1][1][2][1].strip.active, "ticket")
    jump:onClose()
end

-- 用户隐藏的页不出现，顺序不变；条件页不满足时也不出现；全空退回书籍页。
do
    state.sidebar.sidebar_hidden_tabs = { "toc", "ticket" }
    local trimmed = Sidebar:new{ ui = ui, snapshot = state.snapshot }
    Assert.eq(table.concat(trimmed.tabs, ","), "info,notes,xray")
    local strip = trimmed[1][1][2][1].strip
    Assert.len(strip.tabs, 3)
    Assert.eq(strip.tabs[3].id, "xray")

    state.sidebar.sidebar_tab_order = { "xray", "notes" }
    local reordered = Sidebar:new{ ui = ui, snapshot = state.snapshot }
    Assert.eq(table.concat(reordered.tabs, ","), "xray,notes,info")
    state.sidebar.sidebar_tab_order = {}

    state.sidebar.sidebar_hidden_tabs = { "info", "toc", "font", "notes", "ticket" }
    state.xray = { book_xray_enabled = false }
    local fallback = Sidebar:new{ ui = ui, snapshot = state.snapshot }
    Assert.eq(table.concat(fallback.tabs, ","), "info", "只剩不可用的 X-Ray：退回书籍页")
    Assert.eq(fallback[1][1][2][1].strip.tabs[1].id, "info")

    state.sidebar.sidebar_hidden_tabs = {}
    state.xray = { book_xray_enabled = true }
end

-- onCreate 登记手势，事件由 events 接住；非阅读实例不处理
do
    local actions = {}
    package.loaded["dispatcher"] = { registerAction = function(_, id, def) actions[id] = def end }
    Sidebar.onCreate()
    Assert.eq(actions.book_reader_sidebar.event, "BookReaderSidebar")
    Assert.is_true(actions.book_reader_sidebar.reader)
    Assert.is_false(Sidebar.events[actions.book_reader_sidebar.event]({ ui = {} }))
end

return true
