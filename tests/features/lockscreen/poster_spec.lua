--[[--
lockscreen 海报墙：各风格铺满整屏、循环补位，倾斜走三次剪切旋转。

@module tests.features.lockscreen.poster_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")

package.preload["features.lockscreen.components.library"] = function()
    local Library = dofile(package.searchpath("features.lockscreen.components.library", package.path))
    Library.activeSourceId = function() return "moon" end
    Library.shelfBook = function(row, source_id)
        return {
            source_id = source_id,
            stable_id = row.stable_id,
            title = row.title,
            percent = row.percent,
            cover = row.stable_id,
        }
    end
    return Library
end

local db_rows = {}
local db_sources = {}
package.preload["book.catalog"] = function()
    return {
        listBooks = function(source_id)
            db_sources[#db_sources + 1] = source_id
            return db_rows, #db_rows
        end,
        recentBooks = function(source_id, limit)
            db_sources[#db_sources + 1] = source_id
            local rows = {}
            for i = 1, math.min(limit, #db_rows) do rows[i] = db_rows[i] end
            return rows
        end,
    }
end

package.loaded["features.lockscreen.poster"] = nil

local Poster = require("features.lockscreen.poster")
local conf = require("utils.settings").get("features.lockscreen")
conf.lock_screen_poster_style = nil

local function placed(blocks, kind)
    local out = {}
    for _, block in ipairs(blocks) do
        if block.kind == kind then out[#out + 1] = block end
    end
    return out
end

db_rows = {
    { stable_id = "a", title = "A", percent = 10 },
    { stable_id = "b", title = "B", percent = 20 },
    { stable_id = "c", title = "C", percent = 30 },
    { stable_id = "d", title = "D", percent = 40 },
    { stable_id = "e", title = "E", percent = 50 },
}
local wall = placed(Poster.blocks({ x = 0, y = 0, w = 540, h = 720 }), "image")
Assert.eq(db_sources[1], "moon")

-- 错层：4 列均分铺满宽度，单数列上移半张；每列排到盖住屏幕底，5 本书循环补满 18 格。
Assert.eq(#wall, 18)
local expected = {
    { 6, -96 }, { 6, 105 }, { 6, 306 }, { 6, 507 }, { 6, 708 },
    { 139, 0 }, { 139, 201 }, { 139, 402 }, { 139, 603 },
    { 272, -96 },
}
for i, slot in ipairs(expected) do
    Assert.eq(wall[i].x, slot[1])
    Assert.eq(wall[i].y, slot[2])
    Assert.eq(wall[i].width, 129)
    Assert.eq(wall[i].height, 193)
end
Assert.eq(wall[18].x + wall[18].width, 540 - 6, "右边距与左边距对称")
Assert.eq(wall[18].y + wall[18].height >= 720, true, "双数列也要盖住屏幕底")
Assert.eq(wall[1].file, "a")
Assert.eq(wall[5].file, "e")
Assert.eq(wall[6].file, "a", "书不够循环补位")

-- 窄画布：列数随宽度减少，仍然铺满宽度。
local narrow = placed(Poster.blocks({ x = 0, y = 0, w = 200, h = 720 }), "image")
Assert.eq(narrow[1].width, 92)
Assert.eq(narrow[#narrow].x + narrow[#narrow].width, 200 - 6)

-- 单本书也铺满整屏。
local all_rows = db_rows
db_rows = { all_rows[1] }
local single = placed(Poster.blocks({ x = 0, y = 0, w = 540, h = 720 }), "image")
Assert.eq(#single, 18)
for _, block in ipairs(single) do Assert.eq(block.file, "a") end
db_rows = all_rows

-- 未设置风格即竖屏排版（升级前的唯一样式）。
Assert.eq(Poster.style(), "vertical")
conf.lock_screen_poster_style = "bogus"
Assert.eq(Poster.style(), "vertical")
Assert.eq(Poster.styleLabel("bogus"), "竖屏排版")
Assert.eq(#Poster.styleOptions(), 4)
Assert.is_true(Poster.validStyle("slant_left"))
Assert.is_true(not Poster.validStyle("bogus"))

-- 标准布局：4 列 2:3 对齐铺满，行数向上取整、上下均分溢出，书不够循环补位。
conf.lock_screen_poster_style = "standard"
local poster_key = Poster.cache_key()
Assert.matches(poster_key, "^standard:%x+$")
Assert.eq(Poster.cache_key(), poster_key, "书单不变键就稳定")
local saved_rows = db_rows
db_rows = { saved_rows[2], saved_rows[1] }
Assert.is_true(Poster.cache_key() ~= poster_key, "书单变了要重画")
db_rows = saved_rows
conf.lock_screen_poster_style = "vertical"
Assert.is_true(Poster.cache_key() ~= poster_key, "换风格要重画")
conf.lock_screen_poster_style = "standard"
local std = placed(Poster.blocks({ x = 0, y = 0, w = 540, h = 720 }), "image")
Assert.eq(#std, 16)
Assert.eq(std[1].x, 0)
Assert.eq(std[1].y, -42)
Assert.eq(std[1].width, 132)
Assert.eq(std[1].height, 198)
Assert.eq(std[2].x, 136)
Assert.eq(std[5].y, -42 + 202)
Assert.eq(std[6].file, "a")
Assert.eq(std[16].x + std[16].width, 540)

-- 已删除的 3×3 旧配置回退到默认风格。
conf.lock_screen_poster_style = "grid3"
Assert.eq(Poster.style(), "vertical")

-- 斜边：整面墙是一个全屏 widget，封面在 paintTo 里画进离屏图。
-- 假画布存灰度：白 255、黑 0，未写过的像素是 fill 的白。
local Fake = {}
local fake_freed = 0
package.preload["ffi/blitbuffer"] = function()
    return {
        TYPE_BBRGB32 = 1, COLOR_WHITE = 255, COLOR_BLACK = 0,
        new = function(w, h)
            local bb = { w = w, h = h, px = {} }
            function bb:getWidth() return self.w end
            function bb:getHeight() return self.h end
            function bb:fill() self.px = {} end
            function bb:set(x, y, c) self.px[y * self.w + x] = c end
            function bb:get(x, y) return self.px[y * self.w + x] or 255 end
            function bb:free() fake_freed = fake_freed + 1 end
            local function each(dst, src, dx, dy, sx, sy, bw, bh, fn)
                for j = 0, bh - 1 do
                    for i = 0, bw - 1 do
                        local tx, ty, ux, uy = dx + i, dy + j, sx + i, sy + j
                        if tx >= 0 and ty >= 0 and tx < dst.w and ty < dst.h
                            and ux >= 0 and uy >= 0 and ux < src.w and uy < src.h then
                            fn(tx, ty, src:get(ux, uy))
                        end
                    end
                end
            end
            function bb:blitFrom(src, dx, dy, sx, sy, bw, bh)
                each(self, src, dx, dy, sx, sy, bw, bh, function(x, y, v) self:set(x, y, v) end)
            end
            function bb:addblitFrom(src, dx, dy, sx, sy, bw, bh, a)
                each(self, src, dx, dy, sx, sy, bw, bh, function(x, y, v)
                    self:set(x, y, self:get(x, y) * (1 - a) + v * a)
                end)
            end
            return bb
        end,
    }
end
package.loaded["ffi/blitbuffer"] = nil
Fake.new = function(w, h) return require("ffi/blitbuffer").new(w, h) end

conf.lock_screen_poster_style = "slant_right"
local tilted = Poster.blocks({ x = 0, y = 0, w = 540, h = 720 })
Assert.eq(#tilted, 1)
Assert.eq(tilted[1].x, 0)
Assert.eq(tilted[1].widget:getSize().w, 540)
Assert.eq(tilted[1].widget:getSize().h, 720)
local sw, sh = Poster.slantSourceSize(540, 720, math.rad(12))
Assert.is_true(sw > 540 and sh > 720)
tilted[1].widget:free()
conf.lock_screen_poster_style = nil

--- 在源图中心偏移 (ox, oy) 处打一个黑点，旋转后返回输出图里最黑像素的位置（相对中心）。
local function rotatedMarker(w, h, angle, ox, oy)
    local src_w, src_h = Poster.slantSourceSize(w, h, angle)
    local src = Fake.new(src_w, src_h)
    src:set(math.floor(src_w / 2) + ox, math.floor(src_h / 2) + oy, 0)
    local out = Fake.new(w, h)
    Poster.rotateInto(out, 0, 0, w, h, src, angle)
    local best, bx, by = 255, nil, nil
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            if out:get(x, y) < best then
                best, bx, by = out:get(x, y), x, y
            end
        end
    end
    if bx then return bx - math.floor(w / 2), by - math.floor(h / 2) end
end

-- 0°：原样平移。
local x0, y0 = rotatedMarker(40, 60, 0, 5, -7)
Assert.eq(x0, 5)
Assert.eq(y0, -7)

fake_freed = 0
rotatedMarker(41, 41, math.rad(12), 8, 0)
Assert.eq(fake_freed, 3, "源图和两张中间图都要释放")

-- 点落在旋转矩阵给出的位置（插值把点摊到相邻像素，取最黑处；偶数边长的中心差半像素，±1）。
-- 90° 顺时针（屏幕 y 向下）是右 → 下；正角 = 右斜边。
for _, case in ipairs({ { 90, 8, 0 }, { 12, 20, 0 }, { -12, 0, -25 }, { 12, -15, 18 } }) do
    local a = math.rad(case[1])
    local ex = case[2] * math.cos(a) - case[3] * math.sin(a)
    local ey = case[2] * math.sin(a) + case[3] * math.cos(a)
    local rx, ry = rotatedMarker(80, 100, a, case[2], case[3])
    Assert.is_true(rx ~= nil, "旋转后的点不能丢")
    Assert.is_true(math.abs(rx - ex) <= 1 + 1e-9 and math.abs(ry - ey) <= 1 + 1e-9,
        string.format("%d°: got (%d,%d) want (%.1f,%.1f)", case[1], rx, ry, ex, ey))
end

-- 斜边抗锯齿：左半黑右半白的竖直分界旋转后，边上要有中间灰阶，而不只是纯黑纯白的阶梯。
do
    local w, h, angle = 60, 80, math.rad(12)
    local src_w, src_h = Poster.slantSourceSize(w, h, angle)
    local src = Fake.new(src_w, src_h)
    for y = 0, src_h - 1 do
        for x = 0, math.floor(src_w / 2) - 1 do src:set(x, y, 0) end
    end
    local out = Fake.new(w, h)
    Poster.rotateInto(out, 0, 0, w, h, src, angle)
    local gray = 0
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local v = out:get(x, y)
            if v > 8 and v < 247 then gray = gray + 1 end
        end
    end
    Assert.is_true(gray >= h * 0.8, "每行分界处都该有过渡灰阶，got " .. gray)
end

-- 空书库必须显示明确空态，不能静默退化成纯壁纸。
recent = {}
db_rows = {}
local empty = Poster.blocks({ x = 0, y = 0, w = 540, h = 720 })
Assert.eq(#empty, 1)
Assert.eq(empty[1].text, "书库暂无书籍")
Assert.eq(empty[1].align, "center")
