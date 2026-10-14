--[[--
阅读页栏设置预览：字号跟随顶栏 / 底栏设置，顶栏高度跟随「高度」，改完重建即生效。
--]]

local Assert = require("support.assert")

local font = { top = nil }
local top_height = 12
local faces = {}
package.preload["ffi/blitbuffer"] = function() return { Color8 = function(v) return v end } end
package.preload["ui/geometry"] = function() return { new = function(_, o) return o end } end
package.preload["ui/widget/widget"] = function() return { new = function(_, o) return o end } end
package.preload["desktop.pages.setting.overlay"] = function()
    return { previewBox = function(width, inner, h) return { width = width, inner = inner, h = h } end }
end
package.preload["ui.themes"] = function()
    return {
        current = function() return { row = { height = 40 }, progress = { height = 4 }, color = { page = 0, ink = 255 } } end,
        px = function(v) return v end,
    }
end
local painted
package.preload["features.bars.items"] = function()
    return {
        sampleContext = function() return {} end,
        paint = function(_bb, _x, _y, _w, _h, _layout, _ctx, opts) painted = opts end,
    }
end
package.preload["features.bars.layout"] = function()
    return {
        TOP_HEIGHT_DEFAULT = 12,
        fontSize = function(which, fs)
            if which == "top" then return font.top or (fs and fs.text_font_size) or 14 end
            return (fs and fs.text_font_size) or 14
        end,
        topHeight = function() return top_height end,
        get = function() return {} end,
        icons = function() return true end,
    }
end
package.preload["ui/font"] = function()
    return { getFace = function(_, name, size)
        local f = { name = name, size = size }
        faces[#faces + 1] = f
        return f
    end }
end
package.preload["device"] = function() return { screen = { scaleBySize = function(_, v) return v end } } end
local ReaderUIStub = { instance = nil }
package.preload["apps/reader/readerui"] = function() return ReaderUIStub end

local Preview = require("features.bars.preview")

-- 没开书、没全局设置：缺省 14 号，高度按主题行高。
local saved_g = _G.G_reader_settings
_G.G_reader_settings = nil
local top = Preview.build(600, "top")
Assert.eq(top.h, 40)
top.inner:paintTo({ paintRect = function() end }, 0, 0)
Assert.eq(painted.face.size, 14)

-- 开着书：底栏用状态栏字号与字体；顶栏未设置时跟随底栏。
ReaderUIStub.instance = { document = {}, view = { footer = { settings = { text_font_size = 20, text_font_face = "myfont" } } } }
local bottom = Preview.build(600, "bottom")
bottom.inner:paintTo({ paintRect = function() end }, 0, 0)
Assert.eq(painted.face.size, 20)
Assert.eq(painted.face.name, "myfont")
Assert.eq(bottom.h, 56)
Preview.build(600, "top").inner:paintTo({ paintRect = function() end }, 0, 0)
Assert.eq(painted.face.size, 20)

-- 顶栏自己的字号与高度：重建后立即反映。
font.top, top_height = 30, 24
local tall = Preview.build(600, "top")
tall.inner:paintTo({ paintRect = function() end }, 0, 0)
Assert.eq(painted.face.size, 30)
Assert.eq(tall.h, 52, "行高 40 + (24 - 12)")

-- 高度调到 0 也至少容得下一行字。
top_height = 0
Assert.eq(Preview.build(600, "top").h, 38, "30 号字 + 8")

-- 底栏大字号撑高预览条。
ReaderUIStub.instance.view.footer.settings.text_font_size = 60
Assert.eq(Preview.build(600, "bottom").h, 68)

ReaderUIStub.instance = nil
_G.G_reader_settings = saved_g
return true
