--[[-- 书架每行封面数夹在 3–8。 --]]

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")
Kit.display.grid_max_cols = 4
package.preload["ui.widgets.book"] = function() return {} end

local CoverCell = require("ui.widgets.cover")

Assert.eq(CoverCell.gridColsMin(), 3)
Assert.eq(CoverCell.gridColsMax(), 8)
Assert.eq(CoverCell.setGridCols(1), 3)
Assert.eq(Kit.display.grid_max_cols, 3)
Assert.eq(CoverCell.setGridCols(99), 8)
Assert.eq(Kit.display.grid_max_cols, 8)

return true
