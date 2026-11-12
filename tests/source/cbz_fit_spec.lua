--[[--
漫画打包切片：不放大、按屏宽缩小、过高的图切成有界高度的连续页。

@module tests.source.cbz_fit_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()

local Fit = require("source.cbz_fit")

do -- 不放大更窄的图
    local plan = Fit.plan(800, 1000, 1072, 1448)
    Assert.is_true(plan ~= nil)
    Assert.eq(plan.width, 800)
    Assert.eq(plan.height, 1000)
    Assert.len(plan.slices, 1)
    Assert.eq(plan.slices[1].y, 0)
    Assert.eq(plan.slices[1].h, 1000)
    Assert.is_false(Fit.needed(800, 1000, 1072, 1448))
end

do -- 宽于屏幕的图按宽度缩小并保持宽高比
    local plan = Fit.plan(2144, 2000, 1072, 1448)
    Assert.eq(plan.width, 1072)
    Assert.eq(plan.height, 1000)
    Assert.len(plan.slices, 1)
    Assert.is_true(Fit.needed(2144, 2000, 1072, 1448))
end

do -- 过高的图均分成不超过两屏高的若干片
    local screen_w, screen_h = 1072, 1448
    local src_h = screen_h * 5
    local plan = Fit.plan(screen_w, src_h, screen_w, screen_h)
    Assert.eq(plan.width, 1072)
    Assert.eq(plan.height, src_h)
    local max_h = screen_h * Fit.MAX_SCREENS
    Assert.is_true(#plan.slices >= 3)
    local y = 0
    for i, slice in ipairs(plan.slices) do
        Assert.is_true(slice.h <= max_h)
        Assert.eq(slice.y, y)
        y = y + slice.h
    end
    Assert.eq(y, src_h)
    Assert.is_true(Fit.needed(screen_w, src_h, screen_w, screen_h))
end

do -- 只略超两屏时均分，而不是留下一片很短的尾巴
    local screen_w, screen_h = 1072, 1448
    local max_h = screen_h * Fit.MAX_SCREENS
    local plan = Fit.plan(screen_w, max_h + 10, screen_w, screen_h)
    Assert.len(plan.slices, 2)
    Assert.is_true(plan.slices[1].h < max_h)
    Assert.is_true(plan.slices[2].h < max_h)
    Assert.is_true(plan.slices[2].h > 100)
    Assert.eq(plan.slices[1].h + plan.slices[2].h, max_h + 10)
end

do -- 刚好两屏高时不切
    local plan = Fit.plan(1072, 1448 * 2, 1072, 1448)
    Assert.len(plan.slices, 1)
    Assert.eq(plan.slices[1].h, 2896)
end

do -- 页名按序，连续滚动从上到下
    Assert.eq(Fit.pageName(1, ".jpg"), "0001.jpg")
    Assert.eq(Fit.pageName(2, ".webp"), "0002.webp")
    Assert.eq(Fit.pageName(12, ".jpeg"), "0012.jpg")
    Assert.is_true(Fit.pageName(1) < Fit.pageName(2))
    Assert.is_true(Fit.pageName(9) < Fit.pageName(10))
end

do -- 读不出尺寸的图原样登记为一页
    local dir = (os.getenv("TMPDIR") or "/tmp") .. "/moon-cbz-fit-spec"
    os.execute("mkdir -p '" .. dir .. "'")
    local src = dir .. "/0001.jpg"
    local file = assert(io.open(src, "wb"))
    file:write("not-an-image")
    file:close()
    local pages = Fit.materialize(src, dir, 3, 1072, 1448)
    Assert.len(pages, 1)
    Assert.eq(pages[1].path, src)
    Assert.eq(pages[1].name, "0003.jpg")
    Assert.is_false(pages[1].temp)
    os.execute("rm -rf '" .. dir .. "'")
end

do -- 可替换后端按切片写出页，序号连续
    local dir = (os.getenv("TMPDIR") or "/tmp") .. "/moon-cbz-fit-backend"
    os.execute("mkdir -p '" .. dir .. "'")
    local src = dir .. "/tall.bin"
    Fit.backend = {
        dimensions = function() return 1072, 1448 * 5 end,
        writeSlices = function(path, dest, start, plan)
            local pages = {}
            for i, _slice in ipairs(plan.slices) do
                local name = Fit.pageName(start + i - 1, ".jpg")
                local out = dest .. "/" .. name
                local file = assert(io.open(out, "wb"))
                file:write("slice" .. i)
                file:close()
                pages[i] = { path = out, name = name, temp = true }
            end
            Assert.eq(path, src)
            return pages
        end,
    }
    local pages = Fit.materialize(src, dir, 1, 1072, 1448)
    Fit.backend = nil
    Assert.is_true(#pages >= 3)
    Assert.eq(pages[1].name, "0001.jpg")
    Assert.eq(pages[2].name, "0002.jpg")
    Assert.eq(pages[3].name, "0003.jpg")
    local last = 0
    for i, page in ipairs(pages) do
        Assert.eq(page.name, Fit.pageName(i, ".jpg"))
        Assert.is_true(page.name > string.format("%04d", last))
        last = i
        os.remove(page.path)
    end
    os.execute("rm -rf '" .. dir .. "'")
end

do -- 无效尺寸
    Assert.is_nil(Fit.plan(0, 10, 1072, 1448))
    Assert.is_nil(Fit.plan(10, 0, 1072, 1448))
end

return true
