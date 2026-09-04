--[[--
lockscreen 封面海报：电影海报墙错排。

@module tests.lockscreen.components.poster_spec
--]]

local Assert = require("support.assert")

package.preload["lockscreen.components.library"] = function()
    return {
        activeSourceId = function() return "moon" end,
        shelfBook = function(row, source_id)
            return {
                source_id = source_id,
                stable_id = row.stable_id,
                title = row.title,
                percent = row.percent,
            }
        end,
    }
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
Assert.eq(#wall, 5)
Assert.eq(cover_calls, 5)
Assert.eq(db_sources[1], "moon")

local expected = {
    { 6, -96, 128, 192 },
    { 6, 104, 128, 192 },
    { 6, 304, 128, 192 },
    { 138, 0, 128, 192 },
    { 138, 200, 128, 192 },
}
for i, slot in ipairs(expected) do
    Assert.eq(wall[i].x, slot[1])
    Assert.eq(wall[i].y, slot[2])
    Assert.eq(wall[i].width, slot[3])
    Assert.eq(wall[i].height, slot[4])
end

local odd_x = wall[1].x
local even_x
for _, block in ipairs(wall) do
    if block.x ~= odd_x then
        even_x = block.x
        break
    end
end
Assert.is_true(even_x ~= nil)

local odd_col, even_col = {}, {}
for _, block in ipairs(wall) do
    if block.x == odd_x then
        odd_col[#odd_col + 1] = block
    elseif block.x == even_x then
        even_col[#even_col + 1] = block
    end
end

Assert.is_true(#odd_col >= 2)
Assert.is_true(#even_col >= 1)
Assert.is_true(odd_col[1].y < even_col[1].y)
Assert.is_true(odd_col[1].y <= 0)
Assert.eq(odd_col[2].y - odd_col[1].y, odd_col[1].height + 8)

local max_x = 0
for _, block in ipairs(wall) do
    max_x = math.max(max_x, block.x + block.width)
end
Assert.is_true(max_x < 540 * 0.7)

-- 窄画布仍应生成按书籍数量决定的全部列，最右列交给渲染器裁剪。
local narrow = widgetBlocks(Poster.blocks({ x = 0, y = 0, w = 200, h = 720 }))
Assert.eq(#narrow, 5)
Assert.eq(cover_calls, 10)
local narrow_max_x = 0
for _, block in ipairs(narrow) do
    narrow_max_x = math.max(narrow_max_x, block.x + block.width)
end
Assert.is_true(narrow_max_x > 200)
