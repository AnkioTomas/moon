--[[--
lockscreen.render：widget 释放、绘制失败与 PNG 原子替换。

@module tests.lockscreen.render_spec
--]]

local Assert = require("support.assert")

local canvas_frees = 0
local ensured = 0
local removed
local renamed
local rename_ok = true
local snapshot_frees = 0
local cutout_blits = 0
local image_paints = 0
local image_frees = 0
local warnings = 0
local writes = 0
local buffer_types = {}
local rounded_paints = 0
local lightens = {}
local text_log

local function buffer()
    return {
        fill = function() end,
        paintRect = function() end,
        paintRoundedRect = function() rounded_paints = rounded_paints + 1 end,
        lightenRect = function(_, x, y, w, h, by)
            lightens[#lightens + 1] = { x = x, y = y, w = w, h = h, by = by }
        end,
        blitFrom = function() cutout_blits = cutout_blits + 1 end,
        colorblitFrom = function(_, _, x, y, _, _, _, _, color)
            text_log.blit = { x = x, y = y, color = color }
        end,
        copy = function()
            return { free = function() snapshot_frees = snapshot_frees + 1 end }
        end,
        writePNG = function(_, path)
            writes = writes + 1
            Assert.matches(path, "%.part$")
        end,
        free = function()
            canvas_frees = canvas_frees + 1
        end,
    }
end

package.preload["ffi/blitbuffer"] = function()
    return {
        TYPE_BB8 = 1,
        TYPE_BBRGB32 = 2,
        COLOR_WHITE = 0,
        COLOR_BLACK = 1,
        COLOR_GRAY_5 = 5,
        COLOR_GRAY_D = 13,
        new = function(_, _, buffer_type)
            buffer_types[#buffer_types + 1] = buffer_type
            return buffer()
        end,
    }
end

package.loaded["device"] = { screen = { night_mode = false } }
package.preload["ui/font"] = function()
    return { getFace = function() return {} end }
end

package.preload["ui/widget/imagewidget"] = function()
    return {
        new = function(_, opts)
            return {
                paintTo = function() image_paints = image_paints + 1 end,
                free = function() image_frees = image_frees + 1 end,
            }
        end,
    }
end

package.preload["ui/widget/textboxwidget"] = function()
    return { new = function(_, opts)
        text_log.fgcolor = opts.fgcolor
        return {
            _bb = {
                getWidth = function() return opts.width end,
                getHeight = function() return 12 end,
                invertRect = function() text_log.inverted = true end,
            },
            getSize = function() return { w = opts.width, h = 12 } end,
            paintTo = function() text_log.opaque = true end,
            free = function() text_log.freed = true end,
        }
    end }
end

package.preload["utils.paths"] = function()
    return {
        ensureScreensaverDir = function() ensured = ensured + 1 end,
    }
end

package.preload["lockscreen.layout"] = function()
    return {
        portraitSize = function() return 100, 200 end,
    }
end

package.preload["utils.log"] = function()
    return {
        warn = function() warnings = warnings + 1 end,
    }
end

package.loaded["lockscreen.render"] = nil
local Render = require("lockscreen.render")

local real_rename = os.rename
local real_remove = os.remove
os.rename = function(from, to)
    renamed = { from, to }
    return rename_ok
end
os.remove = function(path)
    removed = path
    return true
end

local function reset()
    canvas_frees = 0
    ensured = 0
    removed = nil
    renamed = nil
    rename_ok = true
    snapshot_frees = 0
    cutout_blits = 0
    image_paints = 0
    image_frees = 0
    warnings = 0
    writes = 0
    buffer_types = {}
end

local ok_run, err_run = pcall(function()
    -- 同一个 widget 出现在多个块时只释放一次。
    reset()
    local paints, frees = 0, 0
    local shared = {
        getSize = function() return { w = 10, h = 10 } end,
        paintTo = function() paints = paints + 1 end,
        free = function() frees = frees + 1 end,
    }
    local ok, err = Render.write("/tmp/compose.png", nil, {
        { kind = "widget", widget = shared, x = 0, y = 0 },
        { kind = "widget", widget = shared, x = 20, y = 20 },
    })
    Assert.is_true(ok)
    Assert.is_nil(err)
    Assert.eq(paints, 2)
    Assert.eq(frees, 1)
    Assert.eq(canvas_frees, 1)
    Assert.eq(writes, 1)
    Assert.eq(renamed[1], "/tmp/compose.png.part")
    Assert.eq(renamed[2], "/tmp/compose.png")
    Assert.is_nil(removed)
    Assert.eq(ensured, 1)
    Assert.eq(buffer_types[1], 2, "组合图必须使用彩色缓冲，不能提前丢弃背景颜色")

    -- 票根缺口必须逐行恢复原背景，并释放背景快照。
    reset()
    ok, err = Render.write("/tmp/compose.png", nil, {
        { kind = "panel", x = 10, y = 10, width = 80, height = 100 },
        { kind = "cutout_circle", x = 10, y = 50, radius = 6 },
    })
    Assert.is_true(ok)
    Assert.is_nil(err)
    Assert.is_true(cutout_blits > 0)
    Assert.eq(snapshot_frees, 1)
    Assert.eq(canvas_frees, 1)

    -- 静态图片块由渲染层创建并在绘制后立即释放。
    reset()
    ok, err = Render.write("/tmp/compose.png", nil, {
        { kind = "image", file = "/plugin/logo.png", x = 10, y = 10, width = 32, height = 32 },
    })
    Assert.is_true(ok)
    Assert.is_nil(err)
    Assert.eq(image_paints, 1)
    Assert.eq(image_frees, 1)

    -- 无框文字不得整块贴 TextBoxWidget 白底：黑字蒙版反相后按块颜色 colorblit。
    reset()
    text_log = {}
    ok, err = Render.write("/tmp/compose.png", nil, {
        { text = "字", x = 5, y = 7, width = 40, color = 3, box = false },
    })
    Assert.is_true(ok, tostring(err))
    Assert.is_nil(err)
    Assert.eq(text_log.fgcolor, 1, "蒙版必须用黑字渲染")
    Assert.is_true(text_log.inverted)
    Assert.is_nil(text_log.opaque)
    Assert.eq(text_log.blit.x, 5)
    Assert.eq(text_log.blit.y, 7)
    Assert.eq(text_log.blit.color, 3)
    Assert.is_true(text_log.freed)

    -- 带框文字保持原样：白框 + 原色直接绘制。
    text_log = {}
    ok = Render.write("/tmp/compose.png", nil, { { text = "字", x = 5, y = 7, width = 40, color = 3 } })
    Assert.is_true(ok)
    Assert.eq(text_log.fgcolor, 3)
    Assert.is_true(text_log.opaque)
    Assert.is_nil(text_log.blit)

    -- 半透明卡只混合不填充：不画阴影和实心圆角，行覆盖恰好是整个矩形、圆角行收窄。
    reset()
    rounded_paints = 0
    lightens = {}
    ok, err = Render.write("/tmp/compose.png", nil, {
        { kind = "panel", x = 10, y = 20, width = 60, height = 40, radius = 8, shadow = 2, lighten = 0.75 },
    })
    Assert.is_true(ok)
    Assert.is_nil(err)
    Assert.eq(rounded_paints, 0)
    local rows = 0
    for _, rect in ipairs(lightens) do
        Assert.eq(rect.by, 0.75)
        Assert.is_true(rect.x >= 10 and rect.x + rect.w <= 70)
        Assert.is_true(rect.y >= 20 and rect.y + rect.h <= 60)
        rows = rows + rect.h
    end
    Assert.eq(rows, 40)
    Assert.is_true(lightens[1].w < 60, "顶行在圆角处收窄")
    Assert.eq(lightens[#lightens].w, 60, "中段整宽")

    -- widget 绘制抛错时仍要释放 widget 和画布，且不得进入文件替换。
    reset()
    frees = 0
    local broken = {
        getSize = function() return { w = 10, h = 10 } end,
        paintTo = function() error("paint failed") end,
        free = function() frees = frees + 1 end,
    }
    ok, err = Render.write("/tmp/compose.png", nil, {
        { kind = "widget", widget = broken, x = 0, y = 0 },
    })
    Assert.is_false(ok)
    Assert.matches(tostring(err), "paint failed")
    Assert.eq(frees, 1)
    Assert.eq(canvas_frees, 1)
    Assert.eq(writes, 0)
    Assert.is_nil(renamed)
    Assert.eq(warnings, 0, "渲染错误由锁屏刷新入口统一记录，底层不得重复报警")

    -- rename 失败必须删除临时文件，旧 compose.png 不受影响。
    reset()
    rename_ok = false
    ok, err = Render.write("/tmp/compose.png", nil, {})
    Assert.is_false(ok)
    Assert.matches(tostring(err), "rename failed")
    Assert.eq(writes, 1)
    Assert.eq(renamed[1], "/tmp/compose.png.part")
    Assert.eq(renamed[2], "/tmp/compose.png")
    Assert.eq(removed, "/tmp/compose.png.part")
    Assert.eq(canvas_frees, 1)
    Assert.eq(warnings, 0)
end)

os.rename = real_rename
os.remove = real_remove
if not ok_run then error(err_run) end
