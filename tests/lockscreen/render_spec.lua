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

local function buffer()
    return {
        fill = function() end,
        paintRect = function() end,
        paintRoundedRect = function() end,
        blitFrom = function() cutout_blits = cutout_blits + 1 end,
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
        COLOR_WHITE = 0,
        COLOR_BLACK = 1,
        COLOR_GRAY_5 = 5,
        COLOR_GRAY_D = 13,
        new = function() return buffer() end,
    }
end

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
    return { new = function() error("unexpected text block") end }
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
