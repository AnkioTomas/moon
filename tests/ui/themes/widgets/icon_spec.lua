---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

--[[-- ui.themes.widgets.icon：方盒尺寸、空名字、字面。 --]]

local Assert = require("support.assert")

package.preload["ffi/blitbuffer"] = function()
    return { COLOR_BLACK = 0, COLOR_GRAY = 128 }
end
package.preload["ui.themes"] = function()
    return {
        current = function() return { color = { accent = 0 } } end,
        color = function(value) return value end,
        px = function(n) return n * 2 end,
        fontSize = function(n) return n * 3 end,
        face = function(name, size) return { face = name, size = size } end,
        root = function() return "/plugin/" end,
    }
end
package.preload["ui.themes.widgets.text"] = function()
    return { tint = function(widget) return widget end }
end
package.preload["ui/geometry"] = function()
    return { new = function(_, opts) return opts end }
end
local fail_icon = false
local icon_attempts = 0
package.preload["ui/font"] = function()
    return {
        fontmap = {},
        getFace = function(_, face, size)
            if face == "moon_icon" then
                icon_attempts = icon_attempts + 1
                if fail_icon then return nil end
            end
            return { face = face, size = size }
        end,
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
local metric = Icon.label{ name = "wifi", text = "Wi-Fi", size = 12, color = 7, text_color = 0 }
Assert.eq(metric[1][1].fgcolor, 7)
Assert.eq(metric[3].fgcolor, 0, "指标读数与图标可分色")

fail_icon = true
local fallback = Icon.widget{ name = "home", size = 14 }
Assert.eq(fallback[1].face.face, "cfont", "字体加载失败不能把 nil face 交给 TextWidget")
Assert.eq(fallback[1].text, "?", "降级时不显示未经连字处理的图标名")
local attempts = icon_attempts
Assert.eq(Icon.face(20).face, "cfont")
Assert.eq(icon_attempts, attempts, "坏字体不反复尝试加载")
return true
