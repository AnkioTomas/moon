--[[--
锁屏主体：电影海报墙。

多列大封面从左到右紧凑堆叠；单数列整体上移半张海报（可探出顶边），
双数列顶边对齐。固定行距，不拉伸间距，允许溢出屏幕底。

@module koplugin.book.lockscreen.components.poster
--]]

local BookDB = require("db.book")
local Catalog = require("book.catalog")
local Library = require("lockscreen.components.library")
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
    full_screen = true,
    asset = { id = "none" },
}

--- 取当前源的书并按 stable_id 去重；最近打开的优先，不足再补全量书库。
---@param limit number
---@return table[]
local function books(limit)
    limit = math.max(1, math.floor(tonumber(limit) or 1))
    local source_id = Library.activeSourceId()
    local recent = Catalog.recentBooks(source_id, limit * 2)
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
                result[#result + 1] = Library.shelfBook(row, source_id)
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

--- 全屏海报墙；书库为空时明确显示空态，不能伪装成普通壁纸。
---@param rect table 全屏矩形
---@return table[]
function M.blocks(rect)
    ensureUI()
    local w = math.max(1, tonumber(rect.w) or 1)
    local shelf = books(128)
    local count = #shelf
    if count == 0 then
        return {{
            text = _("书库暂无书籍"),
            x = math.floor(w * 0.1), y = math.floor((rect.h or 1) * 0.47),
            width = math.floor(w * 0.8), size = 22,
            bold = true, align = "center", box = false,
        }}
    end

    local pad_x = UI.sz(6)
    local gap_v = UI.sz(8)
    local gap_h = UI.sz(4)
    local poster_w = math.max(UI.sz(100), math.min(UI.sz(128), math.floor(w * 0.26)))
    local poster_h = math.floor(poster_w * 1.5)
    local lift = math.floor(poster_h * 0.5)
    local row_step = poster_h + gap_v
    -- 列数只由书籍数量决定。最右列可以超出画布，最终由渲染器裁剪。
    local cols = math.min(count, math.max(1, math.ceil(count / 4)))
    local base = math.floor(count / cols)
    local extra = count % cols
    local blocks = {}
    local book_idx = 1
    for col = 0, cols - 1 do
        local rows = base + (col < extra and 1 or 0)
        for row = 0, rows - 1 do
            local widget = select(1, BookInfo.cover(nil, nil, shelf[book_idx], poster_w, poster_h, {
                sync = true,
                shadow = false,
            }))
            blocks[#blocks + 1] = {
                kind = "widget",
                widget = widget,
                x = pad_x + col * (poster_w + gap_h),
                y = row * row_step - (col % 2 == 0 and lift or 0),
                width = poster_w,
                height = poster_h,
            }
            book_idx = book_idx + 1
        end
    end
    return blocks
end

return M
