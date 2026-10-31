--[[-- features.rare.setting：功能 / 显示 / 词库分组；词库进二级页。 --]]

local Assert = require("support.assert")

package.preload["gettext"] = function() return function(text) return text end end
package.preload["ffi/util"] = function()
    return { template = function(s, a) return (s:gsub("%%1", tostring(a))) end }
end

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
local pushed = {}
package.preload["desktop.pages.setting.overlay"] = function()
    return { push = function(_desktop, spec) pushed[#pushed + 1] = spec end }
end
local conf = {
    rare_ruby = false, rare_wordwise = false, rare_enabled = false,
    rare_level = "rare", rare_size = 0.5, rare_color = "gray",
    rare_min_spacing = 140, rare_vocab = false,
    rare_lexicons = { a = true }, rare_split_migrated = true,
}
local saved = 0
package.preload["utils.settings"] = function()
    return { get = function() return conf end, save = function() saved = saved + 1 end }
end
package.preload["features.rare.catalog"] = function()
    return {
        list = function()
            return {
                { id = "a", label = "甲", kind = "ruby" },
                { id = "b", label = "乙", kind = "ruby" },
                { id = "c", label = "丙", kind = "wordwise" },
            }
        end,
        installed = function(id) return id == "a" or id == "c" end,
        enabled = function(id) return id == "a" end,
        kind = function(id) return id == "c" and "wordwise" or "ruby" end,
        active = function() return {} end,
    }
end
local invalidated = 0
package.preload["features.rare.overlay"] = function()
    return { invalidate = function() invalidated = invalidated + 1 end }
end
package.preload["ui/event"] = { new = function() return {} end }

package.loaded["features.rare"] = nil
package.loaded["features.rare.init"] = nil
package.loaded["features.rare.setting"] = nil

local updates = 0
local desktop = { updateView = function() updates = updates + 1 end }
---@cast desktop BookDesktop
local entry = require("features.rare.setting").entries(desktop)[1]
Assert.eq(entry.group, "reader")
Assert.eq(entry.title, "行间标注")
Assert.eq(entry.status, "关")

local sections = entry.page.sections()
Assert.len(sections, 3)
Assert.eq(sections[1].title, "功能")
Assert.eq(sections[2].title, "显示")
Assert.eq(sections[3].title, "词库")

local function expand(sec)
    local rows = {}
    for _j, row in ipairs(sec.rows) do rows[#rows + 1] = row(600) end
    return rows
end

local feature = expand(sections[1])
Assert.len(feature, 2)
Assert.eq(feature[1].title, "生僻字注音")
Assert.eq(feature[2].title, "WordWise 释义")

local display = expand(sections[2])
Assert.len(display, 5)
Assert.len(choices, 4)
Assert.eq(choices[1].title, "标注范围")
Assert.eq(choices[2].title, "标注字号")
Assert.eq(choices[3].title, "标注颜色")
Assert.eq(choices[4].title, "最小行距")
Assert.eq(display[5].title, "生字本也标注")

local lex = expand(sections[3])
Assert.len(lex, 2)
Assert.eq(lex[1].title, "注音词库")
Assert.eq(lex[1].status, "1 个已启用")
Assert.eq(lex[2].title, "释义词库")
-- stub：释义只有 c 已装、未启用 → 已停用
Assert.eq(lex[2].status, "已停用")

-- 开注音（词库 a 已启用）。
feature[1].callback()
Assert.is_true(conf.rare_ruby)
Assert.eq(invalidated, 1)

-- 点词库进二级页。
lex[1].callback()
Assert.len(pushed, 1)
Assert.eq(pushed[1].title, "注音词库")
local sub = pushed[1].sections()
Assert.len(sub, 1)
Assert.len(sub[1].rows, 2)
