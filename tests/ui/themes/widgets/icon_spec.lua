---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

--[[-- ui.themes.widgets.icon：方盒尺寸、空名字、字面。 --]]

local Assert = require("support.assert")

package.preload["ffi/blitbuffer"] = function()
    return { COLOR_BLACK = 0, COLOR_GRAY = 128 }
end
package.preload["ui.themes"] = function()
    return {
        px = function(n) return n * 2 end,
        fontSize = function(n) return n * 3 end,
        face = function(name, size) return { face = name, size = size } end,
        root = function() return "/plugin/" end,
    }
end
package.preload["ui/geometry"] = function()
    return { new = function(_, opts) return opts end }
end
package.preload["ui/font"] = function()
    return {
        fontmap = {},
        getFace = function(_, face, size) return { face = face, size = size } end,
    }
end
local FontList = { fontlist = {}, getFontList = function() end }
package.preload["fontlist"] = function() return FontList end
package.preload["libs/libkoreader-lfs"] = function()
    return { attributes = function() return "file" end }
end
package.preload["utils.log"] = function()
    return { err = function() end }
end
local function widgetModule()
    return { new = function(_, opts)
        opts.getSize = opts.getSize or function(self) return self.dimen end
        return opts
    end }
end
for _, name in ipairs({
    "ui/widget/container/centercontainer",
    "ui/widget/textwidget",
    "ui/widget/horizontalgroup",
    "ui/widget/horizontalspan",
    "ui/widget/verticalgroup",
    "ui/widget/verticalspan",
}) do
    package.preload[name] = widgetModule
end

local Icon = require("ui.themes.widgets.icon")
local icon = Icon.widget{ name = "home", size = 12 }
Assert.eq(icon.dimen.w, 24)
Assert.eq(icon.dimen.h, 24)
Assert.eq(icon[1].face.size, 36)
Assert.eq(icon[1].face.face, "moon_icon")
Assert.is_nil(Icon.widget{})
Assert.eq(FontList.fontlist[1], "/plugin/ui/themes/widgets/icon/MaterialSymbolsOutlined-Regular.ttf")

local label = Icon.label{ name = "wifi", text = "Wi-Fi", size = 12, color = 7 }
Assert.eq(label[1][1].fgcolor, 7)
Assert.eq(label[3].fgcolor, 7)
local dimmed = Icon.label{ name = "wifi", text = "Wi-Fi", size = 12, color = 7, dim = true }
Assert.eq(dimmed[1][1].fgcolor, 128, "dim 图标变灰")
Assert.eq(dimmed[3].fgcolor, 128, "dim 文案变灰")

return true
