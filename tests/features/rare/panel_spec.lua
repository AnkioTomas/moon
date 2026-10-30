--[[-- features.rare.panel：注音 / 释义两个快捷开关；长按开档位菜单。 --]]
local Assert = require("support.assert")
local settings = {
    rare_ruby = false, rare_wordwise = false, rare_enabled = false, rare_level = "rare",
    rare_lexicons = {}, rare_split_migrated = true,
}
local saved, invalidated, toasts, lists = 0, 0, {}, {}
local installed = { ["zh-pinyin"] = true, ["en-gloss-zh"] = true }
package.loaded["utils.settings"] = { get = function() return settings end, save = function() saved = saved + 1 end }
package.loaded["features.rare.overlay"] = { invalidate = function() invalidated = invalidated + 1 end }
package.loaded["features.rare.catalog"] = {
    kind = function(id)
        if id == "en-gloss-zh" or id == "en-gloss-en" then return "wordwise" end
        return "ruby"
    end,
    installed = function(id) return installed[id] == true end,
    active = function() return {} end,
}
package.loaded["ui.themes.widgets.toast"] = { new = function(_self, o) toasts[#toasts + 1] = o.text return { show = function() end } end }
package.loaded["ui.themes.widgets.list"] = { new = function(_self, o) lists[#lists + 1] = o return { show = function() end } end }
package.loaded["ui/uimanager"] = { setDirty = function() end }
package.loaded["ui/event"] = { new = function(_self, name, arg) return { name = name, arg = arg } end }

-- 清掉可能被其它 spec 留下的 features.rare
package.loaded["features.rare"] = nil
package.loaded["features.rare.init"] = nil

local actions = require("features.rare.panel").actions()
Assert.len(actions, 2)
Assert.eq(actions[1].id, "rare_ruby")
Assert.eq(actions[1].title, "生僻字注音")
Assert.eq(actions[2].id, "rare_wordwise")
Assert.eq(actions[2].title, "WordWise 释义")
Assert.is_true(actions[1].keep_open)
Assert.is_false(actions[1].active())
Assert.is_false(actions[2].active())

-- 没启用词库打不开。
actions[1].run({})
Assert.is_false(settings.rare_ruby)
Assert.len(toasts, 1)

settings.rare_lexicons["zh-pinyin"] = true
actions[1].run({})
Assert.is_true(settings.rare_ruby)
Assert.is_true(actions[1].active())

actions[2].run({})
Assert.is_false(settings.rare_wordwise, "没启用释义词库")
settings.rare_lexicons["en-gloss-zh"] = true
actions[2].run({})
Assert.is_true(settings.rare_wordwise)
Assert.is_true(actions[1].active(), "两类可同时开")
Assert.is_true(actions[2].active())

-- 长按档位菜单。
actions[1].hold({})
Assert.eq(lists[1].title, "标注范围")
Assert.len(lists[1].items, 3)
lists[1].items[1].callback()
Assert.eq(settings.rare_level, "rarest")
