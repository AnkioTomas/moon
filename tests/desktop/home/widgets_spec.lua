--[[-- home_widgets 净化、压缩页、容量检查。 --]]

local Assert = require("support.assert")

local store = { home_widgets = {} }
package.preload["utils.settings"] = function()
    return {
        get = function() return store end,
        save = function(_, values)
            if values then store = values end
        end,
    }
end

local Widgets = require("desktop.pages.home.placements")
local components = { { id = "clock" }, { id = "stats" }, { id = "weather" } }

local list = Widgets.sanitize({
    { id = "stats", page = 2, order = 2, height = "fill" },
    { id = "clock", page = 2, order = 1, height = "default" },
    { id = "nope", page = 1, order = 1, height = "default" },
    { id = "clock", page = 9, order = 9, height = "default" },
}, components)
Assert.len(list, 2)
Assert.eq(list[1].id, "clock")
Assert.eq(list[1].order, 1)
Assert.eq(list[2].id, "stats")
Assert.eq(list[2].page, 2)

-- 尚未初始化（非表）才回默认布局。
local fallback = Widgets.sanitize("broken", components)
Assert.len(fallback, 3)
Assert.eq(fallback[1].id, "clock")
Assert.eq(fallback[3].id, "weather")
Assert.eq(fallback[3].page, 1)
Assert.eq(fallback[3].order, 3)
Assert.len(Widgets.sanitize(nil, components), 3, "nil 视为未初始化")

-- 空表或没有合法记录：保持空，不回填默认组件。
Assert.len(Widgets.sanitize({}, components), 0)
Assert.len(Widgets.sanitize({ { id = "nope" } }, components), 0)

store.home_widgets = {}
Assert.len(Widgets.load(components), 0, "空配置读回来仍是空")
store.home_widgets = nil
Assert.len(Widgets.load(components), 3, "缺键仍走首次默认")
Widgets.save({})
Assert.len(store.home_widgets, 0, "空数组能落盘")
Assert.len(Widgets.load(components), 0, "保存后再读不会回填")

Assert.len(Widgets.compactPages({}), 0)

local compacted = Widgets.compactPages({
    { id = "clock", page = 3, order = 1, height = "default" },
    { id = "stats", page = 5, order = 1, height = "default" },
})
Assert.eq(compacted[1].page, 1)
Assert.eq(compacted[2].page, 2)
Assert.eq(Widgets.pageCount(compacted), 2)

Assert.is_true(Widgets.canFit({}, 40, 40, 8))
Assert.is_false(Widgets.canFit({ 30 }, 20, 40, 8))

local page, order = Widgets.appendSlot({
    { id = "clock", page = 1, order = 1, height = "default" },
}, 1, true)
Assert.eq(page, 1)
Assert.eq(order, 2)
page, order = Widgets.appendSlot({
    { id = "clock", page = 1, order = 1, height = "default" },
}, 1, false)
Assert.eq(page, 2)
Assert.eq(order, 1)

return true
