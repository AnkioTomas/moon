--[[-- 反转翻页键：与 KOReader 共用 input_invert_page_turn_keys 与 Device:invertButtons*()。 --]]
local Assert = require("support.assert")
package.preload["ui.themes.widgets.row"] = function() return {} end
package.preload["utils.settings"] = function() return {} end
package.preload["gettext"] = function() return function(t) return t end end
package.loaded["desktop.pages.setting.desktop"] = nil
local S = require("desktop.pages.setting.desktop")

local function gs(init)
    local d = init or {}
    return {
        data = d,
        isTrue = function(_, k) return d[k] == true end,
        makeFalse = function(_, k) d[k] = false end,
        flipNilOrFalse = function(_, k) d[k] = not d[k] end,
    }
end
local calls
local dev = {
    invertButtons = function() calls[#calls + 1] = "all" end,
    invertButtonsLeft = function() calls[#calls + 1] = "left" end,
    invertButtonsRight = function() calls[#calls + 1] = "right" end,
}

calls = {}
local g = gs()
S.swapPageKeys(dev, g)
Assert.eq(g.data.input_invert_page_turn_keys, true)
Assert.eq(table.concat(calls, ","), "all")

calls = {}
S.swapPageKeys(dev, g)
Assert.eq(g.data.input_invert_page_turn_keys, false)
Assert.eq(table.concat(calls, ","), "all")

-- 单侧反转先撤销，避免叠加成错乱映射
calls = {}
g = gs({ input_invert_left_page_turn_keys = true })
S.swapPageKeys(dev, g)
Assert.eq(g.data.input_invert_left_page_turn_keys, false)
Assert.eq(table.concat(calls, ","), "left,all")
