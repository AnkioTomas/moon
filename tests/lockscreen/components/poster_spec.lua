--[[--
lockscreen 海报墙：各风格铺满整屏、循环补位，倾斜走三次剪切旋转。

@module tests.lockscreen.components.poster_spec
--]]

local Assert = require("support.assert")

package.preload["lockscreen.components.library"] = function()
    local Library = dofile(package.searchpath("lockscreen.components.library", package.path))
    Library.activeSourceId = function() return "moon" end
    Library.shelfBook = function(row, source_id)
        return {
            source_id = source_id,
            stable_id = row.stable_id,
            title = row.title,
            percent = row.percent,
        }
    end
    return Library
end

local db_rows = {}
local db_sources = {}
package.preload["db.book"] = function()
    return {
        listBySource = function(source_id)
            db_sources[#db_sources + 1] = source_id
            return db_rows, #db_rows
        end,
    }
end
package.preload["book.catalog"] = function()
    return {
        recentBooks = function(source_id, limit)
            db_sources[#db_sources + 1] = source_id
            local rows = {}
            for i = 1, math.min(limit, #db_rows) do rows[i] = db_rows[i] end
            return rows
        end,
    }
end

local cover_calls = 0
package.preload["ui.components.bookinfo"] = function()
    return {
        cover = function(_, _, book, cw, ch)
            cover_calls = cover_calls + 1
            return {
                paintTo = function() end,
                free = function() end,
                stable_id = book.stable_id,
                cw = cw,
                ch = ch,
            }, cw, ch
        end,
    }
end

package.preload["ui.components.bookui"] = function()
    return {
        sz = function(n) return n end,
    }
end

package.loaded["lockscreen.components.poster"] = nil

local Poster = require("lockscreen.components.poster")

local function widgetBlocks(blocks)
    local widgets = {}
    for _, block in ipairs(blocks) do
        if block.kind == "widget" then
            widgets[#widgets + 1] = block
        end
    end
    return widgets
end

db_rows = {
    { stable_id = "a", title = "A", percent = 10 },
    { stable_id = "b", title = "B", percent = 20 },
    { stable_id = "c", title = "C", percent = 30 },
    { stable_id = "d", title = "D", percent = 40 },
    { stable_id = "e", title = "E", percent = 50 },
}
cover_calls = 0
local wall = widgetBlocks(Poster.blocks({ x = 0, y = 0, w = 540, h = 720 }))
Assert.eq(db_sources[1], "moon")

-- 错层：4 列均分铺满宽度，单数列上移半张；每列排到盖住屏幕底，5 本书循环补满 18 格。
Assert.eq(#wall, 18)
Assert.eq(cover_calls, 18)
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
Assert.eq(wall[1].widget.stable_id, "a")
Assert.eq(wall[5].widget.stable_id, "e")
Assert.eq(wall[6].widget.stable_id, "a", "书不够循环补位")

-- 窄画布：列数随宽度减少，仍然铺满宽度。
local narrow = widgetBlocks(Poster.blocks({ x = 0, y = 0, w = 200, h = 720 }))
Assert.eq(narrow[1].width, 92)
Assert.eq(narrow[#narrow].x + narrow[#narrow].width, 200 - 6)

-- 单本书也铺满整屏。
local all_rows = db_rows
db_rows = { all_rows[1] }
local single = widgetBlocks(Poster.blocks({ x = 0, y = 0, w = 540, h = 720 }))
Assert.eq(#single, 18)
for _, block in ipairs(single) do Assert.eq(block.widget.stable_id, "a") end
db_rows = all_rows

-- 未设置风格即竖屏排版（升级前的唯一样式）。
local MoonSettings = require("utils.settings")
local conf = MoonSettings.get()
Assert.eq(Poster.style(), "vertical")
conf.lock_screen_poster_style = "bogus"
Assert.eq(Poster.style(), "vertical")
Assert.eq(Poster.styleLabel("bogus"), "竖屏排版")
Assert.eq(#Poster.styleOptions(), 4)
Assert.is_true(Poster.validStyle("slant_left"))
Assert.is_true(not Poster.validStyle("bogus"))

-- 标准布局：4 列 2:3 对齐铺满，行数向上取整、上下均分溢出，书不够循环补位。
conf.lock_screen_poster_style = "standard"
Assert.eq(Poster.cache_key(), "standard")
local std = widgetBlocks(Poster.blocks({ x = 0, y = 0, w = 540, h = 720 }))
Assert.eq(#std, 16)
Assert.eq(std[1].x, 0)
Assert.eq(std[1].y, -42)
Assert.eq(std[1].width, 132)
Assert.eq(std[1].height, 198)
Assert.eq(std[2].x, 136)
Assert.eq(std[5].y, -42 + 202)
Assert.eq(std[6].widget.stable_id, "a")
Assert.eq(std[16].x + std[16].width, 540)

-- 已删除的 3×3 旧配置回退到默认风格。
conf.lock_screen_poster_style = "grid3"
Assert.eq(Poster.style(), "vertical")

-- 斜边：整面墙是一个全屏 widget，封面挂在数字子项上（Image.await 要能遍历到）。
local Fake = {}
local fake_freed = 0
package.preload["ffi/blitbuffer"] = function()
    return {
        TYPE_BBRGB32 = 1, COLOR_WHITE = "white", COLOR_BLACK = "black",
        new = function(w, h)
            local bb = { w = w, h = h, px = {} }
            function bb:getWidth() return self.w end
            function bb:getHeight() return self.h end
            function bb:fill() self.px = {} end
            function bb:set(x, y, c) self.px[y * self.w + x] = c end
            function bb:get(x, y) return self.px[y * self.w + x] end
            function bb:free() fake_freed = fake_freed + 1 end
            function bb:blitFrom(src, dx, dy, sx, sy, bw, bh)
                for j = 0, bh - 1 do
                    for i = 0, bw - 1 do
                        local tx, ty, ux, uy = dx + i, dy + j, sx + i, sy + j
                        if tx >= 0 and ty >= 0 and tx < self.w and ty < self.h
                            and ux >= 0 and uy >= 0 and ux < src.w and uy < src.h then
                            self.px[ty * self.w + tx] = src.px[uy * src.w + ux]
                        end
                    end
                end
            end
            return bb
        end,
    }
end
Fake.new = function(w, h) return require("ffi/blitbuffer").new(w, h) end

conf.lock_screen_poster_style = "slant_right"
local tilted = Poster.blocks({ x = 0, y = 0, w = 540, h = 720 })
Assert.eq(#tilted, 1)
Assert.eq(tilted[1].x, 0)
Assert.eq(tilted[1].widget:getSize().w, 540)
Assert.eq(tilted[1].widget:getSize().h, 720)
local sw, sh = Poster.slantSourceSize(540, 720, math.rad(12))
Assert.is_true(sw > 540 and sh > 720)
Assert.is_true(#tilted[1].widget > #std, "倾斜后要多铺封面盖住四角")
local child_freed = 0
for _, child in ipairs(tilted[1].widget) do
    child.free = function() child_freed = child_freed + 1 end
end
tilted[1].widget:free()
Assert.eq(child_freed, #tilted[1].widget)
conf.lock_screen_poster_style = nil

--- 在源图中心偏移 (ox, oy) 处打一个黑点，旋转后返回输出图里黑点的位置（相对中心）。
local function rotatedMarker(w, h, angle, ox, oy)
    local src_w, src_h = Poster.slantSourceSize(w, h, angle)
    local src = Fake.new(src_w, src_h)
    src:set(math.floor(src_w / 2) + ox, math.floor(src_h / 2) + oy, "black")
    local out = Fake.new(w, h)
    Poster.rotateInto(out, 0, 0, w, h, src, angle)
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            if out:get(x, y) == "black" then
                return x - math.floor(w / 2), y - math.floor(h / 2)
            end
        end
    end
end

-- 0°：原样平移。
local x0, y0 = rotatedMarker(40, 60, 0, 5, -7)
Assert.eq(x0, 5)
Assert.eq(y0, -7)

fake_freed = 0
rotatedMarker(41, 41, math.rad(12), 8, 0)
Assert.eq(fake_freed, 3, "源图和两张中间图都要释放")

-- 点落在旋转矩阵给出的位置（最近邻，偶数边长的中心差半像素，±1）。
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

-- 空书库必须显示明确空态，不能静默退化成纯壁纸。
recent = {}
db_rows = {}
local empty = Poster.blocks({ x = 0, y = 0, w = 540, h = 720 })
Assert.eq(#empty, 1)
Assert.eq(empty[1].text, "书库暂无书籍")
Assert.eq(empty[1].align, "center")
