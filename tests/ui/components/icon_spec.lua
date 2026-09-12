--[[-- ui.components.icon：字体图标尺寸与缺失字体降级。 --]]

local Assert = require("support.assert")

package.preload["ffi/blitbuffer"] = function()
    return { COLOR_BLACK = 0 }
end
package.preload["ui.components.bookui"] = function()
    return {
        sz = function(n) return n * 2 end,
        fontSize = function(n) return n * 3 end,
        muted = function() return 7 end,
        pluginRoot = function() return "" end,
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
package.preload["fontlist"] = function()
    return { fontlist = {}, getFontList = function() end }
end
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

local Icon = require("ui.components.icon")
local icon = Icon.widget{ name = "home", size = 12 }
Assert.eq(icon.dimen.w, 24)
Assert.eq(icon.dimen.h, 24)
Assert.eq(icon[1].face.size, 36)
Assert.eq(icon[1].face.face, "moon_icon")
Assert.is_nil(Icon.widget{})

return true
