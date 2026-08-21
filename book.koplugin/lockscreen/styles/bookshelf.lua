--[[--
书籍海报墙锁屏：整屏封面网格，无书柜边框、无层板、无书脊。

正在阅读优先，其余封面补满；无封面用浅灰卡占位。

@module koplugin.book.lockscreen.styles.bookshelf
--]]

local Context = require("lockscreen.context")
local Paths = require("utils.paths")
local Blitbuffer = require("ffi/blitbuffer")
local _ = require("gettext")

local M = { id = "bookshelf", label = _("书架"), local_render = true }

-- 无封面时的卡片底色（墨水屏可读，避开过浅）
local PLACEHOLDER_TONES = {
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

--- 合并在读 + 封面列表，在读优先、按 stable_id 去重。
---@param data { reading: table[], covers: table[] }
---@return table[]
local function collectPosters(data)
    local posters, seen = {}, {}
    local function push(book)
        local id = book.stable_id
        if type(id) ~= "string" or id == "" or seen[id] then
            return
        end
        seen[id] = true
        posters[#posters + 1] = book
    end
    for _, book in ipairs(data.reading or {}) do
        push(book)
    end
    for _, book in ipairs(data.covers or {}) do
        push(book)
    end
    return posters
end

--- 无封面时的浅灰海报卡（无硬边框）。
---@param blocks table[]
---@param x number
---@param y number
---@param cw number
---@param ch number
---@param tone userdata
local function pushPlaceholder(blocks, x, y, cw, ch, tone)
    local radius = math.max(4, math.floor(cw * 0.06))
    blocks[#blocks + 1] = {
        kind = "panel",
        x = x + 2, y = y + 2, width = cw, height = ch,
        radius = radius, color = Blitbuffer.COLOR_GRAY_D,
    }
    blocks[#blocks + 1] = {
        kind = "panel",
        x = x, y = y, width = cw, height = ch,
        radius = radius, color = tone,
    }
    local inset = math.max(6, math.floor(cw * 0.14))
    blocks[#blocks + 1] = {
        kind = "panel",
        x = x + inset, y = y + inset,
        width = cw - inset * 2, height = ch - inset * 2,
        radius = math.max(2, math.floor(radius * 0.6)),
        color = Blitbuffer.COLOR_GRAY_E,
    }
end

--- 推一张海报：有封面走 image，否则占位卡。
---@param blocks table[]
---@param book table
---@param x number
---@param y number
---@param cw number
---@param ch number
---@param day string
local function pushPoster(blocks, book, x, y, cw, ch, day)
    local radius = math.max(4, math.floor(cw * 0.06))
    if book.cover then
        blocks[#blocks + 1] = {
            kind = "image",
            path = book.cover,
            x = x, y = y, width = cw, height = ch,
            matte = Blitbuffer.COLOR_WHITE,
            inset = 0,
            border = false,
            shadow = 2,
            radius = radius,
        }
    else
        local tone = PLACEHOLDER_TONES[(hash((book.stable_id or "") .. "\0" .. day) % #PLACEHOLDER_TONES) + 1]
        pushPlaceholder(blocks, x, y, cw, ch, tone)
    end
end

---@param cb fun(ok: boolean, err: any)
---@return nil
function M.fetch(cb)
    local Render = require("lockscreen.render")
    local w, h = Render.size()
    local day = M.dayKey()
    local posters = collectPosters(Context.bookshelf())

    -- 整屏浅底，不做书柜、不叠壁纸
    local blocks = {
        {
            kind = "panel", x = 0, y = 0, width = w, height = h,
            color = Blitbuffer.COLOR_WHITE,
        },
    }

    local margin = math.max(12, math.floor(w * 0.04))
    local gap = math.max(8, math.floor(w * 0.022))
    local cols = w >= 560 and 4 or 3
    local cell_w = math.floor((w - margin * 2 - gap * (cols - 1)) / cols)
    -- 常见封面比约 2:3
    local cell_h = math.floor(cell_w * 1.45)
    local rows = math.max(1, math.floor((h - margin * 2 + gap) / (cell_h + gap)))
    local capacity = cols * rows
    local grid_h = rows * cell_h + (rows - 1) * gap
    local grid_w = cols * cell_w + (cols - 1) * gap
    local origin_x = math.floor((w - grid_w) / 2)
    local origin_y = math.floor((h - grid_h) / 2)

    if #posters == 0 then
        blocks[#blocks + 1] = {
            text = _("书架还是空的"),
            x = margin, y = math.floor(h * 0.45),
            width = w - margin * 2, size = 22, align = "center", box = false,
            color = Blitbuffer.COLOR_GRAY_6,
        }
    else
        local n = math.min(#posters, capacity)
        for i = 1, n do
            local col = (i - 1) % cols
            local row = math.floor((i - 1) / cols)
            local x = origin_x + col * (cell_w + gap)
            local y = origin_y + row * (cell_h + gap)
            pushPoster(blocks, posters[i], x, y, cell_w, cell_h, day)
        end
    end

    local ok, err = Render.write(M.path(), nil, blocks)
    cb(ok, err)
    return nil
end

return M
