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
package.preload["ui/widget/textwidget"] = function()
    return {
        new = function(_, opts) return opts end,
    }
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

local muted = UI.mutedText("label", 120, 12)
Assert.eq(muted.text, "label")
Assert.eq(muted.max_width, 120)
Assert.not_nil(muted.face)

return true
