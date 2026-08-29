--[[--
锁屏主体：电影海报墙。

多列大封面从左到右紧凑堆叠；单数列整体上移半张海报（可探出顶边），
双数列顶边对齐。固定行距，不拉伸间距，允许溢出屏幕底。

@module koplugin.book.lockscreen.components.poster
--]]

local BookDB = require("utils.db.book")
local MoonSettings = require("utils.settings")
local Paths = require("utils.paths")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")

local UI
local BookInfo

--- 延迟加载桌面同源组件，避免锁屏初始化依赖完整 UI 树。
local function ensureUI()
    if UI then return end
    UI = require("ui.components.bookui")
    BookInfo = require("ui.components.bookinfo")
end

local M = {
    id = "poster",
    label = _("封面海报"),
    supports_position = false,
    live = true,
    full_screen = true,
    asset = { id = "none" },
}

--- 取本地封面缓存路径；无 stable_id 或文件不存在返回 nil。
---@param stable_id string|nil
---@param source_id string|nil
---@return string|nil
local function coverPath(stable_id, source_id)
    if type(stable_id) ~= "string" or stable_id == "" then return nil end
    local path = Paths.coverPath(stable_id, source_id)
    return lfs.attributes(path, "mode") == "file" and path or nil
end

--- 把书库行收敛成海报格子要的字段（含封面路径）。
---@param book table 数据库行
---@param source_id string 行内无 source_id 时的兜底源
---@return table
local function shelfBook(book, source_id)
    local sid = book.source_id or source_id
    local stable_id = book.stable_id
    return {
        source_id = sid,
        stable_id = stable_id,
        title = book.title or stable_id or "",
        authors = book.authors or "",
        percent = tonumber(book.percent) or 0,
        cover = coverPath(stable_id, sid),
    }
end

---@param limit number
---@return table[]
local function books(limit)
    limit = math.max(1, math.floor(tonumber(limit) or 1))
    local source_id = MoonSettings.get().active_source or "local"
    local recent = BookDB.recentBySource(source_id, limit * 2)
    local result, seen = {}, {}

    --- 按 stable_id 去重后追加到结果，总数达 cap 即停。
    ---@param rows table[]|nil
    ---@param cap number
    local function append(rows, cap)
        for _, row in ipairs(rows or {}) do
            if #result >= cap then return end
            local id = row.stable_id
            if type(id) == "string" and id ~= "" and not seen[id] then
                seen[id] = true
                result[#result + 1] = shelfBook(row, source_id)
            end
        end
    end

    append(recent, limit)
    if #result < limit then
        local rows = select(1, BookDB.listBySource(source_id, {
            limit = limit * 2,
            offset = 0,
        }))
        append(rows, limit)
    end
    return result
end

--- 单数列（1-based）上移半张；双数列 y 偏移为 0。列内固定行距，互不重叠。
---@param col number
---@param row number
---@param row_step number
---@param lift number
---@return number
local function slotY(col, row, row_step, lift)
    if col % 2 == 0 then
        return row * row_step - lift
    end
    return row * row_step
end

--- 左列优先，尽量均匀分列。
---@param n number
---@param cols number
---@return number[]
local function columnCounts(n, cols)
    local counts = {}
    local base = math.floor(n / cols)
    local extra = n % cols
    for col = 0, cols - 1 do
        counts[col] = base + (col < extra and 1 or 0)
    end
    return counts
end

---@param w number
---@param count number
---@return table[]
local function slots(w, count)
    ensureUI()
    count = math.max(1, math.floor(tonumber(count) or 1))
    local pad_x = UI.sz(6)
    local gap_v = UI.sz(8)
    local gap_h = UI.sz(4)
    local poster_w = math.max(UI.sz(100), math.min(UI.sz(128), math.floor(w * 0.26)))
    local poster_h = math.floor(poster_w * 1.5)
    local lift = math.floor(poster_h * 0.5)
    local row_step = poster_h + gap_v
    -- 列数只由书籍数量决定。最右列可以超出画布，最终由渲染器裁剪；
    -- 按可用宽度提前删列会直接漏掉海报。
    local cols = math.min(count, math.max(1, math.ceil(count / 4)))
    local counts = columnCounts(count, cols)

    local layout = {}
    local book_idx = 1
    for col = 0, cols - 1 do
        local n = counts[col] or 0
        for row = 0, n - 1 do
            layout[book_idx] = {
                x = pad_x + col * (poster_w + gap_h),
                y = slotY(col, row, row_step, lift),
                w = poster_w,
                h = poster_h,
            }
            book_idx = book_idx + 1
        end
    end
    return layout
end

---@param book table
---@param slot table
---@return table
local function posterWidget(book, slot)
    return select(1, BookInfo.cover(nil, nil, book, slot.w, slot.h, {
        sync = true,
        shadow = false,
    }))
end

---@param rect table
---@return table[]
function M.blocks(rect)
    ensureUI()
    local w = math.max(1, tonumber(rect.w) or 1)
    local shelf = books(128)
    if #shelf == 0 then
        return {}
    end

    local layout = slots(w, #shelf)
    local blocks = {}
    for i, slot in ipairs(layout) do
        local book = shelf[i]
        if not book then
            break
        end
        blocks[#blocks + 1] = {
            kind = "widget",
            role = "poster",
            widget = posterWidget(book, slot),
            x = slot.x,
            y = slot.y,
            width = slot.w,
            height = slot.h,
        }
    end
    return blocks
end

return M
