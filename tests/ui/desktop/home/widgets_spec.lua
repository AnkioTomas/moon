--[[-- home_widgets 净化、压缩页、容量检查。 --]]

local Assert = require("support.assert")

package.preload["utils.settings"] = function()
    return {
        get = function() return { home_widgets = {} } end,
        saveSection = function() end,
    }
end

local Widgets = require("ui.desktop.home.widgets")
local find = function(id)
    return id == "clock" or id == "stats" or id == "weather"
end

local list = Widgets.sanitize({
    { id = "stats", page = 2, order = 2, height = "fill" },
    { id = "clock", page = 2, order = 1, height = "default" },
    { id = "nope", page = 1, order = 1, height = "default" },
    { id = "clock", page = 9, order = 9, height = "default" },
}, find)
Assert.len(list, 2)
Assert.eq(list[1].id, "clock")
Assert.eq(list[1].order, 1)
Assert.eq(list[2].id, "stats")
Assert.eq(list[2].page, 2)

local compacted = Widgets.compactPages({
    { id = "clock", page = 3, order = 1, height = "default" },
    { id = "stats", page = 5, order = 1, height = "default" },
})
Assert.eq(compacted[1].page, 1)
Assert.eq(compacted[2].page, 2)
Assert.eq(Widgets.pageCount(compacted), 2)

Assert.is_true(Widgets.canFit({}, 40, 40, 8))
Assert.is_false(Widgets.canFit({ 30 }, 20, 40, 8))

return true
