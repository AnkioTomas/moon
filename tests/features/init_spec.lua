--[[--
Feature 分发：按 list 顺序调钩子、缺钩子跳过、参数透传、每个 feature 经 guard 隔离。

@module tests.features.init_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")

package.preload["utils.log"] = function()
    return { dbg = function() end }
end

-- bars / sidebar 的 init 就是实现。离线环境没有 SDL / mupdf，挡住它们在文件顶上拉起的前端。
package.preload["device"] = function()
    return {
        hasKeys = function() return false end,
        isTouchDevice = function() return true end,
        screen = {
            scaleBySize = function(_, n) return n end,
            getSize = function() return { w = 600, h = 800 } end,
            getWidth = function() return 600 end,
            getHeight = function() return 800 end,
        },
    }
end
package.preload["gettext"] = function() return function(s) return s end end
package.preload["l10n"] = function() return { apply = function() end } end
local function widget()
    local w = {}
    function w:extend()
        return setmetatable({}, { __index = self })
    end
    return w
end
for _, name in ipairs({
    "ffi/blitbuffer",
    "ui/geometry",
    "ui/gesturerange",
    "ui/uimanager",
    "ui/widget/container/centercontainer",
    "ui/widget/container/framecontainer",
    "ui/widget/container/inputcontainer",
    "ui/widget/horizontalgroup",
    "ui/widget/linewidget",
    "ui/widget/overlapgroup",
    "ui/widget/verticalgroup",
    "ui.themes",
    "ui.themes.widgets.mask",
    "ui.themes.widgets.pager",
    "ui.themes.widgets.tabbar",
    "ui.themes.widgets.text",
}) do
    package.preload[name] = function() return widget() end
end

-- guard 的错误页另有 tests/ui/guard_spec.lua，这里只记下被隔离的错误。
local guarded = {}
package.preload["ui.guard"] = function()
    return {
        call = function(label, fn, ...)
            local ok, res = pcall(fn, ...)
            if ok then return res end
            guarded[#guarded + 1] = { label = label, err = res }
        end,
        wrap = function(_label, fn) return fn end,
    }
end

local seen = {}
local function feature(name, hooks)
    local mod = {}
    for _, hook in ipairs(hooks) do
        mod[hook] = function(plugin, extra)
            seen[#seen + 1] = name .. ":" .. hook .. ":" .. plugin.id .. ":" .. tostring(extra)
        end
    end
    package.preload["features." .. name] = function() return mod end
end
feature("b", { "onCreate", "onSuspend" })
feature("a", { "onCreate" })

require("support.modal_stub").install()
local Features = require("features")

-- 真实 list 的每个条目都能加载。不调用钩子：锁屏/远程的 onCreate 会拉起真实服务。
Assert.eq(table.concat(Features.list, ","), "clock,nightmode,panel,azw3,bars,sidebar,xray,ai,reviews,rare,translate,reflow,animation,dictionary,ocr,baike,lockscreen,passcode,keyboard,ime,remote,update,extensions")
for _, name in ipairs(Features.list) do
    Assert.eq(type(require("features." .. name)), "table")
end

-- 加载器：feature 在自己 init 里登记扩展点；约定文件与 onReaderReady 由加载器代登记；重复调用不重复登记
do
    local Ext = require("utils.extension")
    Features.load()
    Features.load()
    local tabs = {}
    for _, t in ipairs(Ext.list("desktop.tabs")) do tabs[#tabs + 1] = t.id .. ">" .. t.after end
    Assert.eq(table.concat(tabs, ","), "extensions>insight")
    Assert.eq(type(Ext.last("quickpanel.show")), "function")
    Assert.eq(type(Ext.last("topbar.light_percent")), "function")
    Assert.eq(type(Ext.last("highlight.fill_selection")), "function")
    Assert.len(Ext.list("highlight.relabel"), 1)
    Assert.len(Ext.list("desktop.activated"), 2, "校时 + 更新检查")
    Assert.len(Ext.list("desktop.opened"), 0)
    Assert.len(Ext.list("reader.doc_settings"), 1)
    Assert.len(Ext.list("reader.preferences"), 1)
    Assert.len(Ext.list("reader.ready"), 1)
    Assert.eq(Ext.list("note.markup_classes")[1], "moon-tr")
    Assert.len(Ext.list("setting.groups"), 0)
    Assert.is_true(#Ext.list("setting.entries") > 10)
    Assert.is_true(#Ext.list("topbar.items") >= 1)
    local names = {}
    for _, e in ipairs(Ext.list("setting.entries")) do names[#names + 1] = e.name end
    Assert.eq(table.concat(names, ","), table.concat((function()
        local out = {}
        for _, n in ipairs(Features.scan("setting")) do
            if require("features." .. n .. ".setting").entries then out[#out + 1] = n end
        end
        return out
    end)(), ","), "setting.entries 按目录名")
end

-- 顺序即 list 顺序（不按字母）；缺钩子的 feature 跳过
Features.list = { "b", "a" }
local plugin = { id = "p", ui = {} }
Features.emit("onCreate", plugin)
Features.emit("onSuspend", plugin)
Features.emit("onResume", plugin)
Assert.eq(table.concat(seen, ","), "b:onCreate:p:nil,a:onCreate:p:nil,b:onSuspend:p:nil")

-- 空列表不调任何东西
seen = {}
Features.list = {}
Features.emit("onCreate", plugin)
Assert.len(seen, 0)

-- 每个 feature 单独经 guard：坏的报告出去，后面的照常收到钩子
package.preload["features.bad"] = function()
    return { onCreate = function() error("boom") end }
end
seen = {}
Features.list = { "bad", "a" }
Features.emit("onCreate", plugin)
Assert.len(guarded, 1)
Assert.eq(guarded[1].label, "feature bad.onCreate")
Assert.matches(guarded[1].err, "boom")
Assert.eq(table.concat(seen, ","), "a:onCreate:p:nil")

-- events：按 list 顺序分发，参数 = 插件 + 事件参数；返回 true 即停，抛错经 guard 视为未处理
local calls = {}
package.preload["features.e1"] = function()
    return { events = {
        Ping = function(p, x) calls[#calls + 1] = "e1:" .. p.id .. ":" .. x end,
        Boom = function() error("bang") end,
    } }
end
package.preload["features.e2"] = function()
    return { events = { Ping = function(_p, x) calls[#calls + 1] = "e2:" .. x; return true end } }
end
package.preload["features.e3"] = function()
    return { events = { Ping = function() calls[#calls + 1] = "e3" end } }
end
Features.list = { "a", "e1", "e2", "e3" }
local function event(name, ...) return { handler = "on" .. name, args = table.pack(...) } end
Assert.is_true(Features.handleEvent(event("Ping", 7), plugin))
Assert.eq(table.concat(calls, ","), "e1:p:7,e2:7")
Assert.is_false(Features.handleEvent(event("Unknown"), plugin))
guarded = {}
Assert.is_false(Features.handleEvent(event("Boom"), plugin))
Assert.eq(guarded[1].label, "feature e1.events.Boom")

-- scan：扫真实 features/ 目录，返回提供某约定文件的目录名（按名字排序，不看 list），同一文件只扫一次
Assert.eq(table.concat(Features.scan("events"), ","), "xray")
Assert.eq(table.concat(Features.scan("panel"), ","), "ai,animation,bluetooth,demo,nightmode,rare,reflow,remote,reviews,translate,xray")
local settings = Features.scan("setting")
Assert.contains(settings, "nightmode")
Assert.contains(settings, "xray")
for i = 2, #settings do Assert.is_true(settings[i - 1] < settings[i], "按目录名排序") end
Assert.len(Features.scan("no_such_file"), 0)
Assert.eq(Features.scan("events"), Features.scan("events"), "同一文件只扫一次，返回同一张表")

-- listeners：按扫描顺序 require 出各 feature 的约定文件
local listeners = Features.listeners("events")
Assert.len(listeners, 1)
Assert.eq(listeners[1], require("features.xray.events"))
