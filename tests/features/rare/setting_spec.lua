--[[-- features.rare.setting：设置页分节能建出全部行；范围 / 字号是单选行，选中写配置并刷视图，选「全部」提醒性能。 --]]

local Assert = require("support.assert")

package.preload["gettext"] = function() return function(text) return text end end

local choices = {}
package.preload["ui.themes.widgets.row"] = function()
    return {
        widget = function(opts) return opts end,
        choice = function(opts) choices[#choices + 1] = opts; return opts end,
    }
end
local toasts = {}
package.preload["ui.themes.widgets.toast"] = function()
    return { new = function(_self, o) toasts[#toasts + 1] = o.text; return { show = function() end } end }
end
local conf = { rare_enabled = false, rare_level = "rare", rare_size = 0.5, rare_vocab = false }
local saved = 0
package.preload["utils.settings"] = function()
    return { get = function() return conf end, save = function() saved = saved + 1 end }
end
package.preload["features.rare.catalog"] = function()
    return {
        list = function() return { { id = "a", label = "甲" }, { id = "b", label = "乙" } } end,
        installed = function(id) return id == "a" end,
        enabled = function(id) return id == "a" end,
        active = function() return { "a" } end,
    }
end
local invalidated = 0
package.preload["features.rare.overlay"] = function()
    return { invalidate = function() invalidated = invalidated + 1 end }
end

local updates = 0
local desktop = { updateView = function() updates = updates + 1 end }
---@cast desktop BookDesktop
local entry = require("features.rare.setting").entries(desktop)[1]
Assert.eq(entry.group, "reader")
Assert.eq(entry.status, "关")

local sections = entry.page.sections()
Assert.len(sections, 2)
local rows = {}
for _idx, sec in ipairs(sections) do
    for _j, row in ipairs(sec.rows) do rows[#rows + 1] = row(600) end
end
Assert.len(rows, 6, "4 个开关 / 单选行 + 2 本词库")
Assert.len(choices, 2, "范围与字号是单选行")
Assert.eq(choices[1].title, "注音范围")
Assert.eq(choices[1].current, "rare")
Assert.eq(choices[2].title, "注音字号")
Assert.eq(choices[2].current, 0.5)
Assert.eq(rows[5].title, "甲")
Assert.eq(rows[5].status, "已启用")
Assert.eq(rows[6].status, "未下载")

choices[2].on_select(0.6)
Assert.eq(conf.rare_size, 0.6)
Assert.eq(saved, 1)
Assert.eq(invalidated, 1)
Assert.eq(updates, 1)
Assert.len(toasts, 0)

choices[1].on_select("all")
Assert.eq(conf.rare_level, "all")
Assert.len(toasts, 1, "选「全部」提醒性能")
