--[[--
features.lockscreen.render.measureText：字体打不开时不得把 nil face 交给 TextBoxWidget。

模拟器书摘预览曾因此在 Font.getAdjustedFace 崩溃。

@module tests.features.lockscreen.render_measure_spec
--]]

local Assert = require("support.assert")

local faces = {}
local boxes = {}

local function unload()
    local names = {
        "ffi/blitbuffer",
        "device",
        "ui/font",
        "ui/widget/imagewidget",
        "ui/widget/textboxwidget",
        "utils.paths",
        "features.lockscreen.layout",
        "features.lockscreen.render",
    }
    for _idx, name in ipairs(names) do
        package.loaded[name] = nil
        package.preload[name] = nil
    end
end

local function stub(get_face)
    unload()
    local function set(name, value)
        package.preload[name] = function() return value end
        package.loaded[name] = value
    end
    set("ffi/blitbuffer", { COLOR_WHITE = 255, COLOR_BLACK = 0 })
    set("device", { screen = { isColorEnabled = function() return false end, scaleBySize = function(_, n) return n end } })
    set("ui/font", { getFace = get_face })
    set("ui/widget/imagewidget", { new = function() return { paintTo = function() end, free = function() end } end })
    set("ui/widget/textboxwidget", {
        new = function(_, opts)
            Assert.not_nil(opts.face, "TextBoxWidget 不能拿 nil face")
            boxes[#boxes + 1] = opts.face
            return {
                getSize = function() return { w = opts.width, h = 24 } end,
                free = function() end,
            }
        end,
    })
    set("utils.paths", { ensureDir = function() return true end })
    set("features.lockscreen.layout", { portraitSize = function() return 100, 200 end })
    return require("features.lockscreen.render")
end

local function faceOf(_, font)
    faces[#faces + 1] = font
    -- 书摘页脚曾把打不开的 TTC 或未登记的相对路径传进来，getFace 返回 nil。
    if font == "./fonts/noto/NotoSansCJKsc-Regular.otf" then return nil end
    if font == "/System/Library/Fonts/STHeiti Light.ttc" then return nil end
    if font == "cfont" or font == "NotoSans-Regular.ttf" then
        return { name = font, size = 16 }
    end
    return nil
end

local Render = stub(faceOf)

-- 指定字体失败时回退 cfont，测量仍能完成。
faces, boxes = {}, {}
Assert.eq(Render.measureText("月读", 100, 16, false, { face = "/System/Library/Fonts/STHeiti Light.ttc" }), 24)
Assert.eq(boxes[1].name, "cfont")
Assert.is_true(#faces >= 2)

-- 相对路径的自带 Noto 同样要回退，不能把 nil 传进 TextBoxWidget。
faces, boxes = {}, {}
Assert.eq(Render.measureText("书名", 80, 14, true, { face = "./fonts/noto/NotoSansCJKsc-Regular.otf" }), 24)
Assert.eq(boxes[1].name, "cfont")

-- 连 cfont 都没有时估一个高度，仍然不构造 TextBoxWidget。
boxes = {}
local RenderEmpty = stub(function() return nil end) -- getFace(_, font) 一律 nil
local h = RenderEmpty.measureText("书摘一行字", 100, 20, false, { face = "missing.otf", line_height = 0.2 })
Assert.is_true(h >= 20)
Assert.eq(#boxes, 0, "没有可用 face 时不创建 TextBoxWidget")

unload()
return true
