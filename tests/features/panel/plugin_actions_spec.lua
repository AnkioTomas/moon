--[[--
第三方快捷入口：选菜单再选图标、取消不落盘、按侧隔离、执行取当前实例、子菜单复用底栏入口。

@module tests.features.panel.plugin_actions_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, inject-field

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
local Themed = require("support.theme_stubs")
Kit.install("paper")
Themed.install()
Kit.sections.panel = { quick_panel_plugins = {}, quick_panel_actions = {}, quick_panel_reader_actions = {} }

local picker
package.preload["ui.themes.widgets.icon_picker"] = function()
    return { new = function(_self, opts)
        picker = opts
        opts.show = function() end
        return opts
    end }
end
local modules = {
    { name = "book", path = "/book.koplugin" },
    { name = "third", path = "/third.koplugin" },
}
package.preload["pluginloader"] = function() return { loadPlugins = function() return modules end } end
local runs, factory_calls, enabled = {}, 0, true
local function owner(side)
    local ui = {}
    local book = { path = "/book.koplugin", ui = ui }
    ui.book = book
    ui.third = {
        addToMainMenu = function(_self, out)
            out.direct = {
                text = "第三方动作", enabled_func = function() return enabled end,
                callback_func = function()
                    factory_calls = factory_calls + 1
                    return function(menu)
                        runs[#runs + 1] = side
                        menu:closeMenu()
                    end
                end,
            }
            out.sub = { text = "第三方设置", sub_item_table_func = function()
                return { { text = "子动作", callback = function() runs[#runs + 1] = side .. ":sub" end } }
            end }
        end,
    }
    return ui
end
local fm = { instance = owner("desktop") }
local reader = {}
package.preload["apps/filemanager/filemanager"] = function() return fm end
package.preload["apps/reader/readerui"] = function() return reader end

local Actions = require("features.panel.plugin_actions")
local Registry = require("features.panel.actions.registry")
local Desktop = require("features.panel.desktop")
local Reader = require("features.panel.reader")
local cfg = Kit.sections.panel
local picked
Actions.choose("desktop", nil, function(id) picked = id; Desktop.setEnabled(id, true) end)
local list = Themed.last("list")
Assert.is_true(list.centered)
Assert.len(list.items, 2)
Assert.is_nil(picked)
Assert.eq(factory_calls, 0, "列出菜单不解析回调工厂")
Assert.len(cfg.quick_panel_actions, 0)
Themed.choose(list, 1)
Assert.not_nil(picker)
Assert.is_nil(picked, "选择图标前不启用")
Assert.is_nil(next(cfg.quick_panel_plugins), "取消图标选择不会残留半成品")
picker.on_select("star")
local desktop_id = picked
Assert.eq(desktop_id, "plugin:desktop:third:direct")
Assert.eq(cfg.quick_panel_plugins[desktop_id].icon, "star")
Assert.eq(cfg.quick_panel_plugins[desktop_id].entry, "third:direct")
Assert.eq(cfg.quick_panel_actions[1], desktop_id)
Assert.eq(Registry.get(desktop_id).icon, "star")
Assert.eq(Desktop.menuActions()[1].title, "第三方动作")
Assert.len(Reader.actions(nil), 0)

local closed = false
Assert.is_true(Desktop.executeAction(desktop_id, { close = function() closed = true end }))
Assert.is_true(closed)
Assert.eq(runs[1], "desktop")
Assert.eq(factory_calls, 1)
-- 不保留旧 UI 的 callback；打开新阅读会话后从当前阅读实例重新收集。
reader.instance = owner("reader")
Actions.choose("reader", { ui = reader.instance }, function(id) picked = id; Reader.setEnabled(id, true) end)
Themed.choose(Themed.last("list"), 1)
picker.on_select("book")
local reader_id = picked
Assert.eq(reader_id, "plugin:reader:third:direct")
Assert.eq(cfg.quick_panel_plugins[desktop_id].icon, "star")
Assert.eq(cfg.quick_panel_plugins[reader_id].icon, "book")
Assert.is_true(Reader.executeAction(reader_id, reader.instance))
Assert.eq(runs[2], "reader")
reader.instance = owner("new-reader")
Reader.executeAction(reader_id, reader.instance)
Assert.eq(runs[3], "new-reader")

Actions.chooseIcon(desktop_id, function() closed = false end)
Assert.eq(picker.current, "star")
picker.on_select("home")
Assert.eq(Registry.get(desktop_id).icon, "home", "图标变更不被注册表缓存")
Assert.is_false(closed)

Actions.choose("reader", { ui = reader.instance }, function(id) picked = id; Reader.setEnabled(id, true) end)
Themed.choose(Themed.last("list"), 2)
picker.on_select("settings")
Assert.is_true(Reader.executeAction(picked, reader.instance))
list = Themed.last("list")
Assert.eq(list.title, "第三方设置")
Themed.choose(list, 1)
Assert.eq(runs[4], "new-reader:sub")

enabled = false
Assert.is_false(Registry.available(Registry.get(reader_id), { ui = reader.instance }))
Assert.is_false(Reader.executeAction(reader_id, reader.instance), "禁用入口不能绕过原生限制")
enabled = true
modules = { modules[1] }
Assert.is_false(Registry.available(Registry.get(desktop_id), {}))
Assert.len(Desktop.menuActions(), 0, "卸载后不画失效动作，仍保留配置")
Assert.not_nil(cfg.quick_panel_plugins[desktop_id])
-- 执行前入口消失：直接调用执行原语时也有明确反馈。
Registry.get(desktop_id).run({})
Assert.eq(Themed.last("toast").text, "插件入口当前不可用")
Actions.choose("desktop", nil, function() error("empty list should not select") end)
Assert.eq(Themed.last("list").items[1].enabled, false)
Assert.eq(Themed.last("list").items[1].text, "没有可添加的插件入口")

return true
