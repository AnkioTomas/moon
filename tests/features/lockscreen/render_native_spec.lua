--[[--
锁屏写出 × 真实 BlitBuffer / PNG：目录初建、灰度和彩色像素、失败保留旧图。

@module tests.features.lockscreen.render_native_spec
--]]

local Assert = require("support.assert")
local Config = require("support.config")
if not Config.setupNativePath() then
    Assert.skip("需要 KOReader 模拟器原生库")
end

local ffi = require("ffi")
ffi.loadlib = function(name)
    return ffi.load(Config.dir() .. "/libs/lib" .. name .. (ffi.os == "OSX" and ".dylib" or ".so"))
end
package.loaded["ffi/blitbuffer"] = nil
package.preload["ffi/blitbuffer"] = nil
local BB = require("ffi/blitbuffer")
local Png = require("ffi/png")
local Paths = require("utils.paths")
local lfs = require("libs/libkoreader-lfs")
local color_screen = false
package.loaded["device"] = { screen = {
    night_mode = true,
    isColorEnabled = function() return color_screen end,
} }
package.loaded["ui/font"] = {}
package.loaded["ui/widget/imagewidget"] = {}
package.loaded["ui/widget/textboxwidget"] = {}
package.loaded["features.lockscreen.layout"] = { portraitSize = function() return 8, 8 end }
package.loaded["features.lockscreen.render"] = nil
local Render = require("features.lockscreen.render")

local dir = Config.dir() .. "/.moon/lockscreen_render_native"
local path = dir .. "/compose.png"
local function readPNG()
    local file = assert(io.open(path, "rb"))
    local data = file:read("*a")
    file:close()
    return data
end
local function cleanup()
    os.remove(path .. ".part")
    os.remove(path)
    lfs.rmdir(dir)
end

cleanup()
local ok_run, err_run = xpcall(function()
    Assert.is_nil(lfs.attributes(dir))
    for _, color in ipairs({ false, true }) do
        color_screen = color
        local ok, err = Render.write(path, nil, {
            { kind = "rule", x = 0, y = 0, width = 8, height = 1, color = BB.COLOR_BLACK },
        })
        Assert.is_true(ok, tostring(err))
        Assert.eq(lfs.attributes(dir, "mode"), "directory")
        Assert.is_nil(lfs.attributes(path .. ".part"))
        Assert.is_true(package.loaded["device"].screen.night_mode)
        local decoded, image = Png.decodeFromFile(path, color and 4 or 1)
        Assert.is_true(decoded)
        Assert.eq(image.width, 8)
        Assert.eq(image.height, 8)
        Assert.eq(image.data[0], 0, "第一行黑色")
        Assert.eq(image.data[8 * image.ncomp], 255, "后续行白色")
        ffi.C.free(image.data)

        -- 临时文件名被目录占用：真实编码器无法打开，不能继续 rename 或损坏旧图。
        local original = readPNG()
        Assert.is_true((lfs.mkdir(path .. ".part")))
        ok, err = Render.write(path, nil, {})
        Assert.is_false(ok)
        Assert.matches(tostring(err), "cannot write PNG")
        Assert.matches(tostring(err), "failed to open file for writing")
        Assert.eq(readPNG(), original)
        Assert.is_true(package.loaded["device"].screen.night_mode)
        os.remove(path .. ".part")
    end
    color_screen = false
    package.loaded["ui/renderimage"] = { renderImageFile = function()
        return BB.new(8, 8, BB.TYPE_BBRGB32)
    end }
    local ImageWidget = package.loaded["ui/widget/imagewidget"]
    ImageWidget.new = function(_self, options)
        return {
            paintTo = function(_image, bb) bb:blitFrom(options.image) end,
            free = function() options.image:free() end,
        }
    end
    local ok, err, transparent = Render.write(path, { path = "transparent-background" }, {
        { kind = "rule", x = 0, y = 0, width = 8, height = 1, color = BB.COLOR_BLACK },
    })
    Assert.is_true(ok, tostring(err))
    Assert.is_true(transparent)
    local decoded, image = Png.decodeFromFile(path, 4)
    Assert.is_true(decoded)
    Assert.eq(image.data[3], 255, "主体保持不透明")
    Assert.eq(image.data[8 * 4 + 3], 0, "未绘制主体的背景保留透明")
    ffi.C.free(image.data)

    -- writeSize：彩屏 RGB 底必须保持设计色，不能被 fill() 收成灰度。
    color_screen = true
    local card = dir .. "/card.png"
    local cream = BB.ColorRGB32(0xF6, 0xF1, 0xE8, 0xFF)
    local ok_size, err_size = Render.writeSize(card, 8, 8, {}, cream)
    Assert.is_true(ok_size, tostring(err_size))
    decoded, image = Png.decodeFromFile(card, 4)
    Assert.is_true(decoded)
    Assert.eq(image.width, 8)
    Assert.eq(image.data[0], 0xF6, "纸页底 R")
    Assert.eq(image.data[1], 0xF1, "纸页底 G")
    Assert.eq(image.data[2], 0xE8, "纸页底 B")
    ffi.C.free(image.data)
    os.remove(card)

    -- 水平渐变按列插值，不是两截色块。
    local from = BB.ColorRGB32(0x2A, 0x26, 0x22, 0xFF)
    local to = BB.ColorRGB32(0x8A, 0x7A, 0x66, 0xFF)
    ok_size, err_size = Render.writeSize(card, 8, 2, {
        { kind = "hgradient", x = 0, y = 0, width = 8, height = 2, colors = { from, to } },
    }, BB.COLOR_WHITE)
    Assert.is_true(ok_size, tostring(err_size))
    decoded, image = Png.decodeFromFile(card, 4)
    Assert.is_true(decoded)
    Assert.eq(image.data[0], 0x2A, "渐变左端 R")
    Assert.eq(image.data[1], 0x26, "渐变左端 G")
    Assert.eq(image.data[2], 0x22, "渐变左端 B")
    local last = 7 * 4
    Assert.eq(image.data[last], 0x8A, "渐变右端 R")
    Assert.eq(image.data[last + 1], 0x7A, "渐变右端 G")
    Assert.eq(image.data[last + 2], 0x66, "渐变右端 B")
    -- 中点约在 3 或 4 列，应介于两端之间，且左右半边颜色不同。
    local mid = 3 * 4
    Assert.is_true(image.data[mid] > 0x2A and image.data[mid] < 0x8A, "中点 R 在两端之间")
    Assert.is_true(image.data[4] ~= image.data[4 * 4], "不是对半切的两截色")
    ffi.C.free(image.data)
    os.remove(card)

    -- 圆形图片：角上露出底色，中心是图。
    package.loaded["ui/widget/imagewidget"].new = function(_self, options)
        return {
            paintTo = function(_image, bb, x, y)
                local w = options.width or 8
                local h = options.height or 8
                bb:paintRectRGB32(x, y, w, h, BB.ColorRGB32(0x20, 0x80, 0xE0, 0xFF))
            end,
            free = function() end,
        }
    end
    ok_size, err_size = Render.writeSize(card, 8, 8, {
        { kind = "image", file = "logo.png", x = 0, y = 0, width = 8, height = 8, circle = true },
    }, cream)
    Assert.is_true(ok_size, tostring(err_size))
    decoded, image = Png.decodeFromFile(card, 4)
    Assert.is_true(decoded)
    Assert.eq(image.data[0], 0xF6, "圆外左上角露出底色 R")
    Assert.eq(image.data[1], 0xF1, "圆外左上角露出底色 G")
    Assert.eq(image.data[2], 0xE8, "圆外左上角露出底色 B")
    local center = (4 * 8 + 4) * 4
    Assert.eq(image.data[center], 0x20, "圆心是图片色 R")
    Assert.eq(image.data[center + 1], 0x80, "圆心是图片色 G")
    Assert.eq(image.data[center + 2], 0xE0, "圆心是图片色 B")
    ffi.C.free(image.data)
    os.remove(card)

    -- 垂直渐变按行插值；overlay 按透明度叠在底色上。
    local top = BB.ColorRGB32(0x10, 0x0A, 0x06, 0xFF)
    local bottom = BB.ColorRGB32(0x10, 0x0A, 0x06, 0xFF)
    ok_size, err_size = Render.writeSize(card, 8, 8, {
        { kind = "vgradient", x = 0, y = 0, width = 8, height = 8,
            colors = { BB.ColorRGB32(0x00, 0x00, 0x00, 0xFF), BB.ColorRGB32(0xFF, 0xFF, 0xFF, 0xFF) } },
    }, cream)
    Assert.is_true(ok_size, tostring(err_size))
    decoded, image = Png.decodeFromFile(card, 4)
    Assert.is_true(decoded)
    Assert.eq(image.data[0], 0x00, "垂直渐变顶端 R")
    local last_row = 7 * 8 * 4
    Assert.eq(image.data[last_row], 0xFF, "垂直渐变底端 R")
    local mid_row = 3 * 8 * 4
    Assert.is_true(image.data[mid_row] > 0x00 and image.data[mid_row] < 0xFF, "中行介于两端之间")
    ffi.C.free(image.data)
    os.remove(card)

    ok_size, err_size = Render.writeSize(card, 4, 4, {
        { kind = "overlay", x = 0, y = 0, width = 4, height = 4, color = BB.COLOR_BLACK, alpha = 0.5 },
    }, cream)
    Assert.is_true(ok_size, tostring(err_size))
    decoded, image = Png.decodeFromFile(card, 4)
    Assert.is_true(decoded)
    -- 米白 #F6F1E8 与黑 50% 混合，约 #7B7974。
    Assert.is_true(image.data[0] < 0xF6 and image.data[0] > 0x20, "半透明遮罩后不是原底也不全黑")
    ffi.C.free(image.data)
    os.remove(card)

    ok_size, err_size = Render.writeSize(card, 8, 8, {
        { kind = "border", x = 1, y = 1, width = 6, height = 6, border = 1, color = BB.ColorRGB32(0x20, 0x20, 0x20, 0xFF) },
    }, cream)
    Assert.is_true(ok_size, tostring(err_size))
    decoded, image = Png.decodeFromFile(card, 4)
    Assert.is_true(decoded)
    Assert.eq(image.data[0], 0xF6, "描边外仍是底色")
    -- (1,1) 是边框
    local edge = (1 * 8 + 1) * 4
    Assert.eq(image.data[edge], 0x20, "描边色")
    ffi.C.free(image.data)
    os.remove(card)
end, debug.traceback)
cleanup()
if not ok_run then error(err_run) end
