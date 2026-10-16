--[[--
设置树：经 Features.scan 收集 setting.lua 条目（id 前缀、单条误返回报错），
按 分组 → 页面 → 分节 三层合并，同层按 order 排序，非法条目直接报错。

@module tests.desktop.settings.tree_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")

package.loaded["desktop.pages.setting.tree"] = nil
local Tree = require("desktop.pages.setting.tree")

local function sections(title)
    return function() return { { title = title, rows = {} } } end
end

local GROUPS = { { id = "reader", title = "阅读" }, { id = "system", title = "系统" } }

-- ── 收集：按 Features.scan 的顺序；页面 id 加前缀，不改 feature 返回的表 ──
package.preload["features"] = function()
    return {
        scan = function(file) assert(file == "setting") return { "a", "b", "plain" } end,
        external = function() return {}, true end,
    }
end
local b_entries = {
    { id = "main", group = "reader", order = 5, title = "乙", page = { title = "乙", sections = sections("乙") } },
    { parent = "feature:a:1", order = 1, sections = sections("乙追加") },
}
package.preload["features.b.setting"] = function() return { entries = function() return b_entries end } end
package.preload["features.a.setting"] = function()
    return { entries = function()
        return { { group = "system", order = 1, title = "甲", page = { title = "甲", sections = sections("甲") } } }
    end }
end
package.preload["features.plain.setting"] = function() return { defaults = { x = 1 } } end

local collected = Tree.features({})
Assert.len(collected, 3)
Assert.eq(collected[1].id, "feature:a:1", "按扫描顺序；省略 id 用序号")
Assert.eq(collected[1].owner, "feature a")
Assert.eq(collected[2].id, "feature:b:main")
Assert.is_nil(collected[3].id, "追加分节不是页面，不加 id")
Assert.eq(b_entries[1].id, "main", "不改 feature 返回的表")
local again = Tree.features({})
Assert.eq(again[2].id, "feature:b:main", "重复收集不会叠前缀")

-- ── 合并：核心在前、feature 在后，同层按 order；追加分节排在页面自带分节之后 ──
local core = {
    { group = "reader", order = 10, id = "lookup", title = "划词", page = { title = "划词" } },
    { parent = "lookup", order = 90, sections = sections("菜单") },
    { parent = "lookup", order = 10, sections = sections("选区") },
    { group = "system", order = 5, row = function() return "row" end },
}
local entries = {}
for _idx, e in ipairs(core) do entries[#entries + 1] = e end
for _idx, e in ipairs(collected) do entries[#entries + 1] = e end
entries[#entries + 1] = { parent = "lookup", order = 30, sections = sections("翻译"), owner = "feature t" }

local groups = Tree.build(GROUPS, entries)
Assert.eq(groups[1].id, "reader")
Assert.eq(groups[1].title, "阅读")
Assert.len(groups[1].entries, 2)
Assert.eq(groups[1].entries[1].id, "feature:b:main", "order 5 排在 order 10 前")
Assert.eq(groups[1].entries[2].id, "lookup")
Assert.eq(groups[2].entries[1].id, "feature:a:1", "feature 的 order 1 排在核心行 order 5 前")
Assert.eq(groups[2].entries[2].row(), "row")

-- order 相同按收集顺序
local tie = Tree.build(GROUPS, {
    { group = "reader", order = 1, row = function() return "first" end },
    { group = "reader", order = 1, row = function() return "second" end },
})
Assert.eq(tie[1].entries[1].row(), "first")
Assert.eq(tie[1].entries[2].row(), "second")

local lookup = groups[1].entries[2].page
Assert.eq(lookup.id, "lookup")
local titles = {}
for _idx, s in ipairs(lookup.sections()) do titles[#titles + 1] = s.title end
Assert.eq(table.concat(titles, ","), "选区,翻译,菜单", "页面无自带分节时全靠追加，按 order 排")
titles = {}
for _idx, s in ipairs(groups[2].entries[1].page.sections()) do titles[#titles + 1] = s.title end
Assert.eq(table.concat(titles, ","), "甲,乙追加", "feature 也能往别的 feature 页追加")
Assert.is_nil(core[1].page.id, "合并不改核心条目")

-- ── 非法条目直接报错 ──
local function bad(entry, message)
    Assert.errors(function() Tree.build(GROUPS, { entry }) end, message)
end
local page = { title = "x", sections = sections("x") }
bad({ group = "reader", id = "x", page = page }, "needs order")
bad({ group = "nope", order = 1, id = "x", page = page }, "unknown group")
bad({ order = 1, id = "x", page = page }, "group or parent")
bad({ group = "reader", order = 1 }, "page or row")
bad({ group = "reader", order = 1, page = page }, "id and title")
bad({ group = "reader", order = 1, id = "x", page = { title = "x" } }, "no sections")
bad({ parent = "missing", order = 1, sections = sections("x") }, "unknown parent missing")
bad({ parent = "x", order = 1 }, "needs sections")
Assert.errors(function()
    Tree.build(GROUPS, {
        { group = "reader", order = 1, id = "x", page = page },
        { group = "system", order = 1, id = "x", page = page },
    })
end, "duplicate page x")

-- feature 误返回单条设置表
package.preload["features.a.setting"] = function()
    return { entries = function() return { group = "reader", order = 1, page = page } end }
end
package.loaded["features.a.setting"] = nil
Assert.errors(function() Tree.features({}) end, "must return a list")

for _idx, name in ipairs({ "a", "b", "plain" }) do
    package.preload["features." .. name .. ".setting"] = nil
    package.loaded["features." .. name .. ".setting"] = nil
end
