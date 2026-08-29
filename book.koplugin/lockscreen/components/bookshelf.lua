--[[--
锁屏主体：书库封面网格。

封面和网格尺寸直接复用桌面书库的 UI 组件。锁屏只负责把这些组件放到
离屏画布上，不再另造卡片、阴影、进度条或无封面占位样式。

@module koplugin.book.lockscreen.components.bookshelf
--]]

local Blitbuffer = require("ffi/blitbuffer")
local BookDB = require("utils.db.book")
local MoonSettings = require("utils.settings")
local Paths = require("utils.paths")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")

-- 主体注册阶段只需要元数据；真正生成封面时再加载 UI 组件。
local CenterContainer
local FrameContainer
local Geom
local HorizontalGroup
local HorizontalSpan
local TextWidget
local VerticalGroup
local VerticalSpan
local UI
local BookInfo

--- 延迟加载桌面书库同源组件，避免锁屏初始化依赖完整 UI 树。
local function ensureUI()
    if UI then return end
    CenterContainer = require("ui/widget/container/centercontainer")
    FrameContainer = require("ui/widget/container/framecontainer")
    Geom = require("ui/geometry")
    HorizontalGroup = require("ui/widget/horizontalgroup")
    HorizontalSpan = require("ui/widget/horizontalspan")
    TextWidget = require("ui/widget/textwidget")
    VerticalGroup = require("ui/widget/verticalgroup")
    VerticalSpan = require("ui/widget/verticalspan")
    UI = require("ui.components.bookui")
    BookInfo = require("ui.components.bookinfo")
end

local M = {
    id = "bookshelf",
    label = _("书架"),
    supports_position = false,
    live = true,
    full_screen = true,
    uses_background = false,
    asset = { id = "none" },
}

local function activeSourceId()
    if type(MoonSettings.activeSourceId) == "function" then
        return MoonSettings.activeSourceId()
    end
    return MoonSettings.get().active_source or "local"
end

--- 取本地封面缓存路径；无 stable_id 或文件不存在返回 nil（锁屏不触网补图）。
---@param stable_id string|nil
---@param source_id string|nil
---@return string|nil
local function coverPath(stable_id, source_id)
    if type(stable_id) ~= "string" or stable_id == "" then return nil end
    local path = Paths.coverPath(stable_id, source_id)
    return lfs.attributes(path, "mode") == "file" and path or nil
end

--- 把书库行收敛成书架格子要的字段（含封面路径）。
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

--- 读取当前数据源的书架快照；锁屏不触网，只拿本地封面缓存。
---@return { reading: table[], covers: table[] }
function M.data()
    local source_id = activeSourceId()
    local recent = BookDB.recentBySource(source_id, 64)
    local reading, covers, seen = {}, {}, {}

    --- 按 stable_id 去重后追加到目标列表，满 limit 即停。
    ---@param target table[]
    ---@param rows table[]|nil
    ---@param limit number
    ---@param accept fun(row: table): boolean|nil 额外过滤条件
    local function append(target, rows, limit, accept)
        for _, row in ipairs(rows or {}) do
            if #target >= limit then return end
            if not seen[row.stable_id] and (not accept or accept(row)) then
                target[#target + 1] = shelfBook(row, source_id)
                seen[row.stable_id] = true
            end
        end
    end

    append(reading, recent, 12, function(row)
        return (tonumber(row.percent) or 0) < 100
    end)
    if #reading == 0 then append(reading, recent, 8) end
    append(covers, recent, 36)
    if #covers < 24 then
        local rows = select(1, BookDB.listBySource(source_id, { limit = 48, offset = 0 }))
        append(covers, rows, 36)
    end
    return { reading = reading, covers = covers }
end

--- 创建与桌面书库相同的封面格子：封面角标 + 单行书名。
---@param book table
---@param slot_w number
---@param cover_w number
---@param cover_h number
---@return table
local function coverCell(book, slot_w, cover_w, cover_h)
    local cover = select(1, BookInfo.cover(nil, nil, book, cover_w, cover_h, {
        badge = true,
        sync = true,
    }))
    local title = TextWidget:new{
        text = BookInfo.title(book),
        face = UI.face("xx_smallinfofont", 13),
        max_width = slot_w,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    return VerticalGroup:new{
        align = "center",
        CenterContainer:new{
            dimen = Geom:new{ w = slot_w, h = cover_h },
            cover,
        },
        VerticalSpan:new{ width = UI.sz(4) },
        title,
    }
end

--- 创建书库页同源的顶部工具栏，只保留书架名称和总数。
---@param width number
---@param height number
---@param pad number
---@param count number
---@return table
local function header(width, height, pad, count)
    local title = TextWidget:new{
        text = _("书架"),
        face = UI.face("cfont", 17),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local total = TextWidget:new{
        text = string.format(_("共%d本"), count),
        face = UI.face("xx_smallinfofont", 13),
        fgcolor = UI.muted(),
    }
    local content_w = math.max(1, width - pad * 2)
    local spacer = math.max(
        UI.sz(8),
        content_w - title:getSize().w - total:getSize().w
    )
    local row = HorizontalGroup:new{
        align = "center",
        title,
        HorizontalSpan:new{ width = spacer },
        total,
    }
    return FrameContainer:new{
        bordersize = 0,
        padding = 0,
        padding_left = pad,
        padding_right = pad,
        margin = 0,
        width = width,
        height = height,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = content_w, h = height },
            row,
        },
    }
end

--- 读取书架并按稳定身份去重；正在阅读的书保持在最前面。
---@return table[]
local function books()
    local data = M.data()
    local result, seen = {}, {}
    --- 追加一段书列表，跳过缺 stable_id 与已出现过的书。
    ---@param list table[]|nil
    local function append(list)
        for _, book in ipairs(list or {}) do
            local id = book.stable_id
            if type(id) == "string" and id ~= "" and not seen[id] then
                seen[id] = true
                result[#result + 1] = book
            end
        end
    end
    append(data.reading)
    append(data.covers)
    return result
end

--- 生成全屏书库。
---
--- 网格参数与 ui.desktop.library 完全同源；每个封面格子作为 widget 交给
--- render.lua 离屏绘制，因此 BookInfo.cover 的圆角、表面、阴影和角标都能
--- 保持一致。
---@param rect table
---@return table[]
function M.blocks(rect)
    ensureUI()
    local w = math.max(1, tonumber(rect.w) or 1)
    local h = math.max(1, tonumber(rect.h) or 1)
    local pad = UI.sz(10)
    local top_h = UI.sz(52)
    local grid_h = math.max(1, h - top_h)
    local avail_w = math.max(1, w - pad * 2)
    local slot_w, cover_w, cover_h, cols, gap, row_gap, cell_h =
        UI.denseCoverMetrics(avail_w, grid_h, {
            title_extra = UI.sz(4) + UI.sz(22),
        })
    local rows = math.max(1, math.floor((grid_h + row_gap) / (cell_h + row_gap)))
    local capacity = math.max(1, cols * rows)
    local shelf = books()
    local blocks = {
        { kind = "panel", x = 0, y = 0, width = w, height = h,
            color = Blitbuffer.COLOR_WHITE },
        { kind = "widget", role = "header", widget = header(w, top_h, pad, #shelf),
            x = 0, y = 0, width = w, height = top_h },
    }

    if #shelf == 0 then
        blocks[#blocks + 1] = {
            kind = "widget",
            role = "empty",
            widget = CenterContainer:new{
                dimen = Geom:new{ w = w, h = grid_h },
                TextWidget:new{
                    text = _("没有书籍"),
                    face = UI.face("xx_smallinfofont", 14),
                    fgcolor = UI.muted(),
                },
            },
            x = 0, y = top_h, width = w, height = grid_h,
        }
        return blocks
    end

    local visible = math.min(#shelf, capacity)
    for i = 1, visible do
        local zero = i - 1
        local row = math.floor(zero / cols)
        local col = zero % cols
        -- 与桌面书库一样，最后一行从内容区左侧开始，不额外引入另一种排列。
        blocks[#blocks + 1] = {
            kind = "widget",
            role = "cover",
            widget = coverCell(shelf[i], slot_w, cover_w, cover_h),
            x = pad + col * (slot_w + gap),
            y = top_h + row * (cell_h + row_gap),
            width = slot_w,
            height = cell_h,
        }
    end
    return blocks
end

return M
