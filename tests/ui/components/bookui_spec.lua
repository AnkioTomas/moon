--[[-- 网格列数边界。 --]]

local Assert = require("support.assert")

local settings = { grid_max_cols = 4 }
package.preload["device"] = function()
    return { screen = { scaleBySize = function(_, n) return n end } }
end
package.preload["ui/font"] = function()
    return { getFace = function() return {} end }
end
package.preload["ffi/blitbuffer"] = function()
    return {}
end
package.preload["utils.settings"] = function()
    return {
        get = function() return settings end,
        save = function() end,
    }
end

local UI = require("ui.components.bookui")

Assert.eq(UI.gridMaxColsMin(), 3)
Assert.eq(UI.gridMaxColsMax(), 8)
Assert.eq(UI.setGridMaxCols(1), 3)
Assert.eq(settings.grid_max_cols, 3)
Assert.eq(UI.setGridMaxCols(99), 8)
Assert.eq(settings.grid_max_cols, 8)

return true
