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
end, debug.traceback)
cleanup()
if not ok_run then error(err_run) end
