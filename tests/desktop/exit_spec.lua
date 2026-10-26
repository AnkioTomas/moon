--[[--
退出假死回归：桌面 + 文件管理器在窗口栈上，广播 Exit 后栈必须清空（KOReader 普通退出靠空栈收尾）。
覆盖详情页 / 设置浮层打开、onClose 后再 Exit 不重复关、退出兜底清理残留窗口。

@module tests.desktop.exit_spec
--]]

local Assert = require("support.assert")

-- ── 带真实窗口栈的 UIManager（语义对齐 KOReader：close 出栈并回调 onCloseWidget，broadcast 自顶向下）──
local UIManager = { _window_stack = {} }
local close_calls = {}
function UIManager:show(w) self._window_stack[#self._window_stack + 1] = { widget = w } end
function UIManager:close(w)
    for i = #self._window_stack, 1, -1 do
        if self._window_stack[i].widget == w then
            table.remove(self._window_stack, i)
            close_calls[w] = (close_calls[w] or 0) + 1
            if w.onCloseWidget then w:onCloseWidget() end
            return
        end
    end
end
function UIManager:setDirty() end
function UIManager:broadcastEvent(name)
    local checked, i = {}, #self._window_stack
    while i > 0 do
        local w = self._window_stack[i].widget
        if not checked[w] then
            checked[w] = true
            local h = w["on" .. name]
            if h then h(w) end
            i = #self._window_stack
        else
            i = i - 1
        end
    end
end
local function depth() return #UIManager._window_stack end

local function emptyModule() return {} end
local function ctorModule() return { new = function(_, o) return o or {} end } end
for _, name in ipairs({
    "ui/bidi", "ffi/blitbuffer", "ui/gesturerange", "ui/widget/overlapgroup", "utils.perf",
    "ui.themes", "ui.themes.widgets.box", "ui.themes.widgets.tabbar",
}) do
    package.preload[name] = emptyModule
end
package.preload["utils.log"] = function()
    local l = {}
    for _, k in ipairs({ "dbg", "info", "warn", "err", "error", "flush" }) do l[k] = function() end end
    return l
end
for _, name in ipairs({
    "desktop.pages.home", "desktop.pages.library", "desktop.pages.store",
    "desktop.pages.insight", "desktop.pages.setting", "desktop.topbar",
}) do
    package.preload[name] = ctorModule
end
package.preload["ui/uimanager"] = function() return UIManager end
package.preload["ui/geometry"] = ctorModule
package.preload["desktop.gesture"] = function() return { range = function() return {} end } end
package.preload["gettext"] = function() return function(text) return text end end
package.preload["utils.settings"] = function() return { get = function() return {} end } end
package.preload["device"] = function()
    return {
        screen = { getWidth = function() return 600 end, getHeight = function() return 800 end },
        hasKeys = function() return false end,
        hasFewKeys = function() return true end,
    }
end
local InputContainer = {}
function InputContainer:extend(value) return setmetatable(value, { __index = self }) end
package.preload["ui/widget/container/inputcontainer"] = function() return InputContainer end

package.loaded["desktop"] = nil
local Desktop = require("desktop")
Desktop.build = function() end
local ExitWindows = require("ui.exit_windows")

--- 子窗口（详情页 / 设置浮层）：Modal 语义，close 出栈并回调 close_callback
local function child(desktop, field)
    local c = { book_window = true, closed = false }
    function c:close() UIManager:close(self) end
    function c:onCloseWidget()
        self.closed = true
        if desktop[field] == self then desktop[field] = nil end
    end
    UIManager:show(c)
    desktop[field] = c
    return c
end

--- FileManager：收到 Exit → DeviceListener:exitOrRestart → onClose 出栈；插件 onExit 兜底
local function fileManager()
    local fm = {}
    function fm:onExit()
        UIManager:close(self)
        ExitWindows.close()
    end
    UIManager:show(fm)
    return fm
end

local function newDesktop(plugin)
    local d = setmetatable({ key_events = {}, plugin = plugin, source = { id = "local" } }, { __index = Desktop })
    d:init()
    plugin.desktop = d
    UIManager:show(d)
    return d
end

local function reset()
    UIManager._window_stack = {}
    close_calls = {}
end

-- 1) 桌面盖在 FM 上：Exit 后栈空，桌面只关一次，plugin.desktop 解绑
do
    reset()
    local plugin = {}
    local fm = fileManager()
    local d = newDesktop(plugin)
    Assert.eq(depth(), 2)
    UIManager:broadcastEvent("Exit")
    Assert.eq(depth(), 0, "window stack must be empty after Exit")
    Assert.eq(close_calls[d], 1)
    Assert.eq(close_calls[fm], 1)
    Assert.is_true(d.closed)
    Assert.is_nil(plugin.desktop)
end

-- 2) 详情页 + 设置浮层开着：一起关掉，栈空，各关一次
do
    reset()
    local plugin = {}
    fileManager()
    local d = newDesktop(plugin)
    local detail = child(d, "detail")
    local overlay = child(d, "settings_overlay")
    Assert.eq(depth(), 4)
    UIManager:broadcastEvent("Exit")
    Assert.eq(depth(), 0, "detail/overlay must not survive Exit")
    Assert.eq(close_calls[detail], 1)
    Assert.eq(close_calls[overlay], 1)
    Assert.is_true(detail.closed)
    Assert.is_nil(d.detail)
    Assert.is_nil(d.settings_overlay)
end

-- 3) Desktop:onExit 返回 false，广播继续送给 FM
do
    reset()
    local d = newDesktop({})
    Assert.eq(d:onExit(), false)
    Assert.eq(depth(), 0)
    -- 已关闭后再 Exit：不重复关
    Assert.eq(d:onExit(), false)
    Assert.eq(close_calls[d], 1)
end

-- 4) 先 onClose（返回首页 / 打开书），之后 Exit：不重复 destroy / 关窗
do
    reset()
    local plugin = {}
    local fm = fileManager()
    local d = newDesktop(plugin)
    Assert.is_true(d:onClose())
    Assert.eq(depth(), 1)
    UIManager:broadcastEvent("Exit")
    Assert.eq(depth(), 0)
    Assert.eq(close_calls[d], 1)
    Assert.eq(close_calls[fm], 1)
end

-- 5) 兜底：桌面之外的残留月读窗口（如 toast / 弹窗）在插件 onExit 时被清掉；非月读窗口不动
do
    reset()
    local fm = fileManager()
    local toast = { book_window = true }
    UIManager:show(toast)
    local other = {}
    UIManager:show(other)
    Assert.eq(ExitWindows.close(), 1)
    Assert.eq(close_calls[toast], 1)
    Assert.is_nil(close_calls[other])
    Assert.is_nil(close_calls[fm])
    -- 已销毁但仍在栈上的桌面（旧版行为）也会被兜底关窗
    reset()
    local d = newDesktop({})
    d:destroy()
    Assert.eq(depth(), 1)
    Assert.eq(ExitWindows.close(), 1)
    Assert.eq(depth(), 0)
end

-- 6) 退出开始后（ReaderUI 关书在下一 tick）再弹的月读窗口（关书出错的错误页等）不上栈，否则等不到空栈而假死
do
    reset()
    for _, name in ipairs({
        "ui/widget/horizontalgroup", "ui/widget/horizontalspan", "ui/widget/verticalgroup",
        "ui/widget/verticalspan", "ui.themes.widgets.button", "ui.themes.widgets.mask", "ui.themes.widgets.text",
    }) do
        package.preload[name] = package.preload[name] or ctorModule
    end
    package.loaded["ui.themes.widgets.modal"] = nil
    local Modal = require("ui.themes.widgets.modal")
    local before = setmetatable({}, { __index = Modal })
    before:show()
    Assert.eq(depth(), 1)
    reset()
    ExitWindows.exiting = true
    local late = setmetatable({}, { __index = Modal })
    late:show()
    ExitWindows.exiting = false
    Assert.eq(depth(), 0, "Modal shown after Exit must not stay on the stack")
end

-- 4) 销毁后重开：页签与书架浏览位置还原，换源不还原
do
    reset()
    local plugin = {}
    local d = newDesktop(plugin)
    d.tab = "library"
    d.library.group, d.library.page, d.library.filter = "books", 3, { search = "x" }
    d:destroy()
    local d2 = newDesktop(plugin)
    Assert.eq(d2.tab, "library")
    Assert.eq(d2.library.page, 3)
    Assert.eq(d2.library.filter.search, "x")
    local source = { id = "wechat" }
    ---@cast source BookSource
    d2.source = source
    d2:destroy()
    local d3 = newDesktop(plugin)
    Assert.eq(d3.tab, "home", "换源不还原")
end
