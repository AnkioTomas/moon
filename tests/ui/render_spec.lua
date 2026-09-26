--[[--
ui.render：离屏写 PNG 时关掉 night_mode（否则 ImageWidget 预先反色，存成底片），结束和出错都恢复。
@module tests.ui.render_spec
--]]

local Assert = require("support.assert")

local screen = { night_mode = true }
package.loaded["device"] = { screen = screen }

local written = {}
package.loaded["ffi/blitbuffer"] = {
    TYPE_BBRGB32 = 1,
    COLOR_WHITE = 255,
    new = function()
        return {
            fill = function() end,
            writePNG = function(_, path) written[#written + 1] = path end,
            free = function() end,
        }
    end,
}

local real_rename = os.rename
os.rename = function() return true end

package.loaded["ui.render"] = nil
local Render = require("ui.render")

do -- 夜间模式下绘制：画的时候 night_mode 是关的，画完恢复
    local during
    local ok = Render.write("/tmp/x.png", 4, 4, function() during = screen.night_mode end)
    Assert.is_true(ok)
    Assert.is_false(during, "离屏绘制期间必须关掉 night_mode")
    Assert.is_true(screen.night_mode, "写完恢复夜间模式")
    Assert.eq(written[1], "/tmp/x.png.part")
end

do -- 绘制出错也要恢复
    local ok = Render.write("/tmp/y.png", 4, 4, function() error("boom") end)
    Assert.is_false(ok)
    Assert.is_true(screen.night_mode, "出错后恢复夜间模式")
end

do -- 日间模式保持日间
    screen.night_mode = false
    Render.write("/tmp/z.png", 4, 4, function() end)
    Assert.is_false(screen.night_mode)
end

os.rename = real_rename
