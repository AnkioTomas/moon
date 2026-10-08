--[[-- 夜间与亮度设置行：自动夜间一行，有前光时再加自动亮度一行。 --]]

local Assert = require("support.assert")

package.preload["gettext"] = function() return function(text) return text end end
package.preload["ffi/util"] = function()
    return { template = function(text, value) return (text:gsub("%%1", tostring(value))) end }
end
package.preload["ui.themes.widgets.row"] = function()
    return { widget = function(opts) return opts end }
end
require("support.theme_stubs").install()

local frontlight = true
package.preload["device"] = function()
    return { hasFrontlight = function() return frontlight end }
end
local night_window
package.preload["utils.settings"] = function()
    return {
        get = function(name)
            assert(name == "features.nightmode")
            return { auto_night = night_window and "schedule" or "off", auto_light = false }
        end,
    }
end
package.preload["features.nightmode"] = function()
    return {
        window = function() if night_window then return night_window[1], night_window[2] end end,
        hasSensor = function() return false end,
    }
end

package.loaded["features.nightmode.page"] = nil
local Page = require("features.nightmode.page")
local rows = Page.rows({})
Assert.len(rows, 2)
Assert.eq(rows[1](600).title, "自动夜间模式")
Assert.eq(rows[1](600).status, "关")
Assert.is_false(rows[1](600).status_on)
night_window = { 22 * 60, 7 * 60 }
Assert.eq(rows[1](600).status, "22:00–07:00")
Assert.is_true(rows[1](600).status_on)
Assert.eq(rows[2](600).title, "自动亮度")
Assert.eq(rows[2](600).status, "关")
Assert.is_false(rows[2](600).status_on)
Assert.eq(rows[2](600).subtitle, "按时段和天气调节；手动调亮度会关闭自动亮度")

frontlight = false
Assert.len(Page.rows({}), 1, "无前光不展示自动亮度")
