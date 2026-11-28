--[[-- 桌面返回键：登记 group.Back；叠层 / 详情先关；页内 onBack；根页广播 Exit 退出。 --]]
---@diagnostic disable: missing-fields

local Assert = require("support.assert")

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
package.preload["ui/geometry"] = ctorModule
local broadcasts = {}
package.preload["ui/uimanager"] = function()
    return {
        _window_stack = {},
        broadcastEvent = function(_, event)
            broadcasts[#broadcasts + 1] = event and event.name or event
        end,
    }
end
package.preload["ui/event"] = function()
    return { new = function(_, name) return { name = name } end }
end
package.preload["desktop.gesture"] = function()
    return { range = function() return {} end, dispatcher = function(fm) return { fm = fm } end }
end
package.preload["gettext"] = function() return function(text) return text end end
package.preload["utils.settings"] = function() return { get = function() return {} end } end
local confirm_shown
package.preload["ui.themes.widgets.confirm"] = function()
    return { new = function(_, o) return { show = function() confirm_shown = o end } end }
end
package.preload["device"] = function()
    return {
        screen = { getWidth = function() return 600 end, getHeight = function() return 800 end },
        hasKeys = function() return true end,
        hasFewKeys = function() return false end,
        hasDPad = function() return false end,
        input = { group = { Back = { "Back" } } },
    }
end
local InputContainer = {}
function InputContainer:extend(value) return setmetatable(value, { __index = self }) end
function InputContainer.onKeyRepeat() return false end
package.preload["ui/widget/container/inputcontainer"] = function() return InputContainer end

package.loaded["desktop"] = nil
local Desktop = require("desktop")
Desktop.build = function() end

local function make()
    local d = setmetatable({ key_events = {}, plugin = { ui = {} }, tab = "home" }, { __index = Desktop })
    d:init()
    return d
end

local d = make()
Assert.is_true(d.key_events.DesktopBack ~= nil)
Assert.eq(d.key_events.DesktopBack[1][1][1], "Back")

local closed = {}
d.settings_overlay = { close = function() closed[#closed + 1] = "overlay" end }
d.tab = "settings"
d.settings = { onBack = function() closed[#closed + 1] = "settings-page"; return true end }
Assert.is_true(d:onDesktopBack())
Assert.eq(table.concat(closed, ","), "overlay")

closed = {}
d.settings_overlay = nil
d.detail = { closed = false, close = function(self) closed[#closed + 1] = "detail"; self.closed = true end }
Assert.is_true(d:onDesktopBack())
Assert.eq(table.concat(closed, ","), "detail")

closed = {}
d.detail = nil
d.tab = "library"
d.library = { onBack = function() closed[#closed + 1] = "library"; return true end }
Assert.is_true(d:onDesktopBack())
Assert.eq(table.concat(closed, ","), "library")

-- 非首页的根页（页内无法后退）：先回首页，不退出
local switched
d.switchTab = function(_, id) switched = id end
broadcasts = {}
d.tab = "library"
d.library = { onBack = function() return false end }
Assert.is_true(d:onDesktopBack())
Assert.eq(switched, "home", "非首页根页 Back 回首页")
Assert.len(broadcasts, 0)
d.switchTab = nil

-- 首页根页：弹确认，确认后才广播 Exit
d.tab = "home"
d.home = {}
Assert.is_true(d:onDesktopBack())
Assert.len(broadcasts, 0, "确认前不退出")
Assert.not_nil(confirm_shown, "首页 Back 弹确认")
confirm_shown.ok_callback()
Assert.eq(table.concat(broadcasts, ","), "Exit", "确认后广播 Exit")

local key = {
    match = function(_, seq)
        local g = seq[1]
        return g == "Back" or (type(g) == "table" and g[1] == "Back")
    end,
}
Assert.is_true(d:onKeyRepeat(key))

-- 真实 Library:onBack / Store:onBack（轻量 stub 依赖后 require）
package.preload["desktop.pages.library"] = nil
package.loaded["desktop.pages.library"] = nil
for _, name in ipairs({
    "ui/widget/container/centercontainer", "ui/widget/horizontalgroup", "ui/widget/horizontalspan",
    "ui/widget/leftcontainer", "ui/widget/linewidget", "ui/widget/verticalgroup", "ui/widget/verticalspan",
    "ui.widgets.cover", "desktop.pages.library.filter", "desktop.pages.library.rows",
    "ui.themes.widgets.button", "ui.themes.widgets.input", "ui.themes.widgets.pager",
    "ui.themes.widgets.tap", "ui.themes.widgets.text", "ui.input", "ffi/util",
}) do
    package.preload[name] = emptyModule
end
package.preload["ffi/util"] = function() return { template = function(_, s) return s end } end
package.preload["ui.themes"] = function()
    return { current = function() return { color = {}, space = { sm = 1, md = 1 } } end, px = function(n) return n or 0 end }
end
package.preload["ui.themes.widgets.box"] = emptyModule
package.loaded["utils.settings"] = nil
package.preload["utils.settings"] = function()
    return {
        get = function() return { library_tabs = { "books", "author", "folder" }, library_view = "grid" } end,
        getSource = function() return {} end,
        save = function() end,
    }
end
package.loaded["source.local.common"] = nil
package.preload["source.local.common"] = function()
    return { rootPath = function() return "/books" end }
end
package.preload["gettext"] = function() return function(t) return t end end

local Library = require("desktop.pages.library")
local updates = 0
local lib = setmetatable({
    filter = { author = "鲁迅" },
    group = "author",
    group_page = 1,
    desktop = { updateView = function() updates = updates + 1 end },
}, { __index = Library })
Assert.is_true(lib:onBack())
Assert.is_nil(lib.filter.author)
Assert.eq(updates, 1)
Assert.is_false(lib:onBack())

lib.group = "folder"
lib.dir = "/books/foo/bar"
local opened = {}
local real_open = lib.openDir
function lib:openDir(dir)
    opened[#opened + 1] = dir
    return real_open(self, dir)
end
Assert.is_true(lib:onBack())
Assert.eq(opened[1], "/books/foo")
lib.dir = "/books"
Assert.is_false(lib:onBack())

package.preload["desktop.pages.store"] = nil
package.loaded["desktop.pages.store"] = nil
for _, name in ipairs({
    "book.store", "source.store_cache", "store.zlib", "store.opds", "desktop.detail",
}) do
    package.preload[name] = emptyModule
end
package.preload["book.store"] = emptyModule
package.preload["source.store_cache"] = function()
    return { browse = function() end }
end
local Store = require("desktop.pages.store")
local store = setmetatable({
    trail = { { title = "a", feed = "http://a" }, { title = "b", feed = "http://b" } },
    page = 1,
    desktop = { updateView = function() end },
}, { __index = Store })
function store:cancel() end
Assert.is_true(store:onBack())
Assert.len(store.trail, 1)
Assert.is_true(store:onBack())
Assert.len(store.trail, 0)
Assert.is_false(store:onBack())

return true
