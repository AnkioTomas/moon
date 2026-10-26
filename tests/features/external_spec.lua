--[[--
第三方 feature（moon_source.lua 的 provides.features）：收集、加前缀、校验、出错隔离、未加载完不缓存。

@module tests.features.external_spec
--]]
---@diagnostic disable: undefined-field, missing-fields

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(s) return s end end
for _idx, id in ipairs({ "night", "wifi", "rotate", "refresh", "screenshot", "frontlight", "suspend", "power" }) do
    package.preload["features.panel.actions.desktop." .. id] = function()
        return { id = id, title = id, icon = "x", scope = "desktop" }
    end
end
for _idx, id in ipairs({ "toc", "font", "highlights", "bookorbit", "push_progress", "pull_progress", "reload_chapter", "save_default" }) do
    package.preload["features.panel.actions.reader." .. id] = function()
        return { id = id, title = id, icon = "x", scope = "reader" }
    end
end

local calls = {}
package.preload["extdemo.panel"] = function()
    return {
        actions = function()
            return {
                { id = "toggle", title = "T", icon = "tune", scope = "desktop", run = function() error("boom") end,
                    active = function() return true end },
                { id = "noscope", title = "T", icon = "tune", run = function() end },
                { id = "ext.demo.reader", title = "R", icon = "tune", scope = "reader", event = "X" },
                { id = "night", title = "N", icon = "tune", scope = "desktop", event = "X" }, -- 加前缀后不撞内置
            }
        end,
    }
end

local ready = false
local exts = {
    { id = "ext.demo", features = {
        panel = "extdemo.panel",
        setting = { entries = function()
            return {
                { id = "main", group = "reader", order = 300, title = "Demo",
                    page = { title = "Demo", sections = function() error("bad sections") end } },
                { group = "nosuchgroup", order = 1, row = function() end },
                { parent = "nosuchpage", order = 1, sections = function() return {} end },
                { order = 1 }, -- 缺 group / parent
            }
        end },
        events = {
            book_removed = function(...) calls[#calls + 1] = { ... }; error("sub boom") end,
        },
        hooks = { onReaderReady = function(plugin) calls.hook = plugin; error("hook boom") end },
    } },
    { id = "ext.broken", features = { panel = "no.such.module", setting = { entries = function() return { order = 1 } end } } },
    { id = "ext.none" },
}
package.loaded["source.registry"] = {
    extensions = function() return ready and exts or {} end,
    extensionsReady = function() return ready end,
}

package.loaded["features"] = nil
local Features = require("features")

-- 前缀
Assert.eq(Features.prefix("ext.a", "x"), "ext.a.x")
Assert.eq(Features.prefix("ext.a", "ext.a.x"), "ext.a.x")
Assert.eq(Features.prefix("ext.a", ""), nil)
Assert.eq(Features.prefix("ext.a", 3), nil)

-- 插件没加载完：空且 ready 为假
do
    local items, ok = Features.external("panel")
    Assert.eq(#items, 0)
    Assert.eq(ok, false)
end

-- 快捷面板：加载期间收集的不缓存，加载完重收
package.loaded["features.panel.actions.registry"] = nil
local Panel = require("features.panel.actions.registry")
Assert.eq(Panel.get("ext.demo.toggle"), nil)
ready = true
do
    local items = Features.external("panel")
    Assert.eq(#items, 1, "坏模块名记日志跳过")
    Assert.eq(items[1].id, "ext.demo")
end
local desktop = Panel.desktopOrder()
Assert.eq(desktop[#desktop - 1], "ext.demo.toggle")
Assert.eq(desktop[#desktop], "ext.demo.night")
local reader = Panel.readerOrder()
Assert.eq(reader[#reader], "ext.demo.reader")
Assert.eq(Panel.get("ext.demo.noscope"), nil, "缺 scope 跳过")
local toggle = Panel.get("ext.demo.toggle")
Assert.eq(Panel.active(toggle, nil), true)
Panel.execute(toggle, {}, {}) -- run 抛错只记日志
Assert.eq(Panel.available(Panel.get("ext.gone.x"), nil), false, "卸载插件的已存 id 静默跳过")

-- 数据事件：订阅方出错也当成功，不打断核心派发
do
    local listeners, ok = Features.listeners("events")
    Assert.eq(ok, true)
    local last = listeners[#listeners]
    Assert.eq(last.book_removed("wechat", "b1"), true)
    Assert.eq(calls[1][2], "b1")
end

-- 钩子：只转发 onReaderReady，出错不抛
do
    local list = Features.list
    Features.list = {}
    local p0, p1 = {}, {}
    ---@cast p0 BookPlugin
    ---@cast p1 BookPlugin
    Features.emit("onCreate", p0)
    Assert.eq(calls.hook, nil)
    Features.emit("onReaderReady", p1)
    Assert.eq(calls.hook, p1)
    Features.list = list
end

-- 设置树：第三方条目加页面前缀，不合格的记日志跳过，不报错
do
    package.loaded["desktop.pages.setting.tree"] = nil
    local Tree = require("desktop.pages.setting.tree")
    Features.scan = function() return {} end -- 内置 feature 的设置页要拉界面模块，这里只看第三方
    local entries = {}
    for _idx, entry in ipairs(Tree.features(nil)) do
        if entry.external then entries[#entries + 1] = entry end
    end
    Assert.eq(#entries, 4, "ext.broken 的单表返回整份拒绝")
    Assert.eq(entries[1].id, "feature:ext.demo:main")
    local groups = Tree.build({ { id = "reader", title = "R" } }, entries)
    Assert.eq(#groups[1].entries, 1)
    local page = groups[1].entries[1].page
    Assert.eq(page.id, "feature:ext.demo:main")
    Assert.eq(#page.sections(), 0, "sections 抛错只记日志")
end
