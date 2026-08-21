--[[--
物理书架锁屏：整屏书柜，不叠壁纸。

  第 1 层 — 正在阅读：书脊（多数竖放，偶尔斜靠/横放/平躺）
  第 2–4 层 — 封面朝外，左起摆放，高低略有参差

@module koplugin.book.lockscreen.styles.bookshelf
--]]

local Context = require("lockscreen.context")
local Paths = require("utils.paths")
local Blitbuffer = require("ffi/blitbuffer")
local _ = require("gettext")

local M = { id = "bookshelf", label = _("书架"), local_render = true }

-- 墨水屏可读的书脊灰度；避开过浅与纯黑
local SPINE_COLORS = {
    Blitbuffer.COLOR_GRAY_3,
    Blitbuffer.COLOR_GRAY_4,
    Blitbuffer.COLOR_GRAY_5,
    Blitbuffer.COLOR_GRAY_6,
    Blitbuffer.COLOR_DARK_GRAY,
    Blitbuffer.COLOR_GRAY_7,
}

---@return string
function M.path()
    return Paths.screensaverDir() .. "/bookshelf.png"
end

---@return string
function M.dayKey()
    return os.date("%Y-%m-%d")
end

---@param s string
---@return number
local function hash(s)
    local h = 0
    for i = 1, #s do
        h = (h * 33 + s:byte(i)) % 2147483647
    end
    return h
end

--- 姿态加权：竖放为主，其余点缀，避免顶层像被打翻。
---@param book table
---@param day string
---@return string pose, string dir, userdata color, number thick_bias
local function styleFor(book, day)
    local h = hash((book.stable_id or "") .. "\0" .. day)
    local r = h % 100
    local pose
    if r < 58 then
        pose = "vertical"
    elseif r < 78 then
        pose = "tilt"
    elseif r < 90 then
        pose = "flat"
    else
        pose = "horizontal"
    end
    local dir = (math.floor(h / 7) % 2 == 0) and "right" or "left"
    local color = SPINE_COLORS[(math.floor(h / 11) % #SPINE_COLORS) + 1]
    local thick_bias = (math.floor(h / 3) % 5) - 2 -- -2..+2
    return pose, dir, color, thick_bias
end

---@param blocks table[]
---@param x number
---@param y number
---@param w number
---@param board_h number
local function pushBoard(blocks, x, y, w, board_h)
    -- 层板本体
    blocks[#blocks + 1] = {
        kind = "panel", x = x, y = y, width = w, height = board_h,
        color = Blitbuffer.COLOR_GRAY_5,
    }
    -- 上沿亮线 + 下沿阴影：厚度
    blocks[#blocks + 1] = {
        kind = "rule", x = x, y = y, width = w, height = 1,
        color = Blitbuffer.COLOR_GRAY_B,
    }
    blocks[#blocks + 1] = {
        kind = "rule", x = x, y = y + board_h - 1, width = w, height = 1,
        color = Blitbuffer.COLOR_GRAY_2,
    }
    -- 落在层板下的软影
    blocks[#blocks + 1] = {
        kind = "panel", x = x + 2, y = y + board_h, width = w - 4, height = 3,
        color = Blitbuffer.COLOR_GRAY_D,
    }
end

--- 书柜外框：左右立柱 + 顶底横梁。
---@param blocks table[]
---@param frame table {x,y,w,h,post,beam}
local function pushCabinet(blocks, frame)
    local x, y, w, h = frame.x, frame.y, frame.w, frame.h
    local post, beam = frame.post, frame.beam
    -- 柜内背板（略深，衬托书）
    blocks[#blocks + 1] = {
        kind = "panel", x = x, y = y, width = w, height = h,
        color = Blitbuffer.COLOR_GRAY_E,
    }
    -- 顶梁
    blocks[#blocks + 1] = {
        kind = "panel", x = x, y = y, width = w, height = beam,
        color = Blitbuffer.COLOR_GRAY_4,
    }
    blocks[#blocks + 1] = {
        kind = "rule", x = x, y = y + beam - 1, width = w, height = 1,
        color = Blitbuffer.COLOR_GRAY_2,
    }
    -- 底梁
    blocks[#blocks + 1] = {
        kind = "panel", x = x, y = y + h - beam, width = w, height = beam,
        color = Blitbuffer.COLOR_GRAY_4,
    }
    -- 左右立柱（后画，压住层板端头）
    blocks[#blocks + 1] = {
        kind = "panel", x = x, y = y, width = post, height = h,
        color = Blitbuffer.COLOR_GRAY_4,
    }
    blocks[#blocks + 1] = {
        kind = "panel", x = x + w - post, y = y, width = post, height = h,
        color = Blitbuffer.COLOR_GRAY_4,
    }
    -- 外轮廓：DESIGN 克制边框，用深灰而非纯黑硬框
    blocks[#blocks + 1] = {
        kind = "rule", x = x, y = y, width = w, height = 1,
        color = Blitbuffer.COLOR_GRAY_3,
    }
    blocks[#blocks + 1] = {
        kind = "rule", x = x, y = y + h - 1, width = w, height = 1,
        color = Blitbuffer.COLOR_GRAY_3,
    }
    blocks[#blocks + 1] = {
        kind = "panel", x = x, y = y, width = 1, height = h,
        color = Blitbuffer.COLOR_GRAY_3,
    }
    blocks[#blocks + 1] = {
        kind = "panel", x = x + w - 1, y = y, width = 1, height = h,
        color = Blitbuffer.COLOR_GRAY_3,
    }
end

---@param blocks table[]
---@param books table[]
---@param day string
---@param left number
---@param top number
---@param inner_w number
---@param book_h number
local function layoutSpines(blocks, books, day, left, top, inner_w, book_h)
    local x = left
    local gap = math.max(3, math.floor(inner_w * 0.008))
    local base_spine = math.max(12, math.floor(book_h * 0.10))
    for _, book in ipairs(books) do
        local pose, dir, color, thick_bias = styleFor(book, day)
        local spine_w = math.max(10, base_spine + thick_bias * 2)
        local bw, bh, by
        if pose == "vertical" then
            bw, bh, by = spine_w, book_h, top
        elseif pose == "tilt" then
            local lean = math.floor(book_h * 0.10)
            bw, bh, by = spine_w + lean, book_h, top
        elseif pose == "horizontal" then
            bw = math.floor(book_h * 0.38)
            bh = math.max(11, math.floor(spine_w * 1.2))
            by = top + book_h - bh
        else -- flat：平躺一摞的观感
            bw = math.floor(book_h * 0.48)
            bh = math.max(9, math.floor(spine_w * 0.75))
            by = top + book_h - bh
        end
        if x + bw > left + inner_w then
            break
        end
        local lean_px = pose == "tilt" and math.floor(book_h * 0.10) or 0
        local sx, sw = x, bw
        if pose == "tilt" then
            sw = spine_w
            if dir == "left" then
                sx = x + lean_px
            end
        end
        blocks[#blocks + 1] = {
            kind = "spine",
            x = sx, y = by, width = sw, height = bh,
            pose = pose, dir = dir, lean = 0.10,
            color = color, band = pose == "vertical" or pose == "tilt",
            shadow = 2,
            -- 书脊不写字：窄条上的字在墨水屏上就是噪点
        }
        x = x + bw + gap
    end
end

--- 无封面时画布面精装占位，不塞标题文字。
---@param blocks table[]
---@param x number
---@param y number
---@param cw number
---@param ch number
---@param tone userdata
local function pushBoundPlaceholder(blocks, x, y, cw, ch, tone)
    blocks[#blocks + 1] = {
        kind = "panel", x = x + 2, y = y + 2, width = cw, height = ch,
        color = Blitbuffer.COLOR_GRAY_9,
    }
    blocks[#blocks + 1] = {
        kind = "panel", x = x, y = y, width = cw, height = ch,
        color = tone,
    }
    local inset = math.max(4, math.floor(cw * 0.12))
    blocks[#blocks + 1] = {
        kind = "panel",
        x = x + inset, y = y + inset,
        width = cw - inset * 2, height = ch - inset * 2,
        color = Blitbuffer.COLOR_GRAY_E,
    }
    blocks[#blocks + 1] = {
        kind = "rule",
        x = x + inset, y = y + math.floor(ch * 0.22),
        width = cw - inset * 2, height = 1,
        color = Blitbuffer.COLOR_GRAY_7,
    }
    blocks[#blocks + 1] = {
        kind = "rule",
        x = x + inset, y = y + math.floor(ch * 0.78),
        width = cw - inset * 2, height = 1,
        color = Blitbuffer.COLOR_GRAY_7,
    }
    blocks[#blocks + 1] = {
        kind = "rule", x = x, y = y, width = cw, height = 1,
        color = Blitbuffer.COLOR_GRAY_3,
    }
    blocks[#blocks + 1] = {
        kind = "panel", x = x, y = y, width = 1, height = ch,
        color = Blitbuffer.COLOR_GRAY_3,
    }
    blocks[#blocks + 1] = {
        kind = "panel", x = x + cw - 1, y = y, width = 1, height = ch,
        color = Blitbuffer.COLOR_GRAY_3,
    }
    blocks[#blocks + 1] = {
        kind = "rule", x = x, y = y + ch - 1, width = cw, height = 1,
        color = Blitbuffer.COLOR_GRAY_3,
    }
end

---@param blocks table[]
---@param books table[]
---@param start_i number
---@param left number
---@param shelf_top number 层板顶面 y（书底对齐）
---@param inner_w number
---@param max_h number 本层最大书高
---@param day string
---@return number next_index
local function layoutCovers(blocks, books, start_i, left, shelf_top, inner_w, max_h, day)
    local gap = math.max(8, math.floor(inner_w * 0.025))
    local cw = math.max(28, math.floor(max_h * 2 / 3))
    local x = left
    local i = start_i
    while i <= #books do
        local book = books[i]
        local h = hash((book.stable_id or "") .. "\0" .. day)
        -- 高度参差：85%～100%，底边齐层板
        local ch = math.max(24, math.floor(max_h * (0.85 + (h % 16) / 100)))
        local cy = shelf_top - ch
        if x + cw > left + inner_w then
            break
        end
        if book.cover then
            blocks[#blocks + 1] = {
                kind = "image",
                path = book.cover,
                x = x, y = cy, width = cw, height = ch,
                matte = Blitbuffer.COLOR_GRAY_E,
                inset = 2,
                border = true,
                border_color = Blitbuffer.COLOR_GRAY_5,
                shadow = 2,
                radius = math.max(4, math.floor(cw * 0.06)),
            }
        else
            local tone = SPINE_COLORS[(h % #SPINE_COLORS) + 1]
            pushBoundPlaceholder(blocks, x, cy, cw, ch, tone)
        end
        x = x + cw + gap
        i = i + 1
    end
    return i
end

---@param cb fun(ok: boolean, err: any)
---@return table|nil
function M.fetch(cb)
    -- 书柜自带整屏底色，不叠必应/自定义壁纸（叠上去只会脏）
    local Render = require("lockscreen.render")
    local w, h = Render.size()
    local day = M.dayKey()
    local data = Context.bookshelf()

    local margin = math.floor(w * 0.04)
    local frame = {
        x = margin,
        y = math.floor(h * 0.03),
        w = w - margin * 2,
        h = h - math.floor(h * 0.06),
        post = math.max(10, math.floor(w * 0.035)),
        beam = math.max(12, math.floor(h * 0.022)),
    }
    local board_h = math.max(10, math.floor(h * 0.018))
    local inset = frame.post + math.max(6, math.floor(w * 0.015))
    local left = frame.x + inset
    local inner_w = frame.w - inset * 2
    local content_top = frame.y + frame.beam + math.max(4, math.floor(h * 0.008))
    local content_bot = frame.y + frame.h - frame.beam - 2
    local usable = content_bot - content_top
    -- 顶层略高（书脊），下面三层均分
    local spine_slot = math.floor(usable * 0.28)
    local cover_slot = math.floor((usable - spine_slot) / 3)

    local blocks = {
        -- 屏外底：干净浅灰，不要壁纸噪声
        { kind = "panel", x = 0, y = 0, width = w, height = h, color = Blitbuffer.COLOR_GRAY_D },
    }
    pushCabinet(blocks, frame)

    local function shelfBand(slot_top, slot_h)
        local book_h = slot_h - board_h - 4
        local shelf_y = slot_top + slot_h - board_h
        return book_h, shelf_y, slot_top + 2
    end

    if #data.reading == 0 and #data.covers == 0 then
        blocks[#blocks + 1] = {
            text = _("书架还是空的"),
            x = left, y = math.floor(h * 0.45),
            width = inner_w, size = 22, align = "center", box = false,
            color = Blitbuffer.COLOR_GRAY_6,
        }
        local y = content_top
        for i = 0, 3 do
            local slot_h = i == 0 and spine_slot or cover_slot
            local _, shelf_y = shelfBand(y, slot_h)
            pushBoard(blocks, left - 2, shelf_y, inner_w + 4, board_h)
            y = y + slot_h
        end
    else
        local y = content_top
        local book_h, shelf_y = shelfBand(y, spine_slot)
        layoutSpines(blocks, data.reading, day, left, shelf_y - book_h, inner_w, book_h)
        pushBoard(blocks, left - 2, shelf_y, inner_w + 4, board_h)
        y = y + spine_slot

        local cover_i = 1
        for _ = 1, 3 do
            book_h, shelf_y = shelfBand(y, cover_slot)
            cover_i = layoutCovers(blocks, data.covers, cover_i, left, shelf_y, inner_w, book_h, day)
            pushBoard(blocks, left - 2, shelf_y, inner_w + 4, board_h)
            y = y + cover_slot
        end
    end

    -- 立柱再盖一层，把层板端头收进柜体
    blocks[#blocks + 1] = {
        kind = "panel", x = frame.x, y = frame.y, width = frame.post, height = frame.h,
        color = Blitbuffer.COLOR_GRAY_4,
    }
    blocks[#blocks + 1] = {
        kind = "panel", x = frame.x + frame.w - frame.post, y = frame.y,
        width = frame.post, height = frame.h,
        color = Blitbuffer.COLOR_GRAY_4,
    }
    blocks[#blocks + 1] = {
        kind = "panel", x = frame.x, y = frame.y, width = 1, height = frame.h,
        color = Blitbuffer.COLOR_GRAY_3,
    }
    blocks[#blocks + 1] = {
        kind = "panel", x = frame.x + frame.w - 1, y = frame.y, width = 1, height = frame.h,
        color = Blitbuffer.COLOR_GRAY_3,
    }

    local ok, err = Render.write(M.path(), nil, blocks)
    cb(ok, err)
    return nil
end

return M
