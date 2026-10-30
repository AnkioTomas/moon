--[[--
锁屏背景：海报墙。书库封面自绘铺满整屏，主体组件照常叠在上面。

风格：
- vertical（竖屏排版，默认）：错层墙，单数列整体上移半张海报（可探出顶边），
  双数列顶边对齐；列宽均分铺满宽度，固定行距排到盖住屏幕底。
- standard：2:3 封面 4 列整齐对齐、按宽铺满，多出的高度上下均分裁掉。
- slant_left / slant_right：标准网格整面倾斜；先画进离屏大图，再三次剪切旋转贴到画布。
所有风格都铺满整屏，书不够时循环补位。

@module koplugin.book.features.lockscreen.poster
--]]

local Catalog = require("book.catalog")
local Library = require("features.lockscreen.components.library")
local MoonSettings = require("utils.settings")
local _ = require("gettext")

local U = require("features.lockscreen.components.util")

local DEFAULT_STYLE = "vertical"
local DEFAULT_SORT = "recent_read"
local SLANT = math.rad(12)

local SORTS = {
    { id = "recent_read", label = _("最近阅读") },
    { id = "recent_added", label = _("最近添加") },
}

local SORT_BY_ID = {}
for _idx, sort in ipairs(SORTS) do SORT_BY_ID[sort.id] = sort end

local M = {}

--- 取当前源的书并按 stable_id 去重；排序看设置（最近阅读 / 最近添加）。
---@param limit number
---@return table[]
local function books(limit)
    local source_id = Library.activeSourceId()
    local result = {}
    local append = Library.shelfCollector(source_id)
    append(result, (Catalog.listBooks(source_id, {
        limit = limit * 2,
        offset = 0,
        sort = M.sort(),
    })), limit)
    return result
end

--- 错层海报墙：列宽按目标尺寸均分铺满宽度，单数列上移半张探出顶边；
--- 每列排到盖住屏幕底为止，书不够循环补位。
---@param shelf table[]
---@return table[]
local function staggered(shelf, w, h)
    -- w 是物理像素（锁屏画布 = 屏幕真实分辨率），尺寸一律按宽度比例算：
    -- 写死像素在 1272 宽的 Kindle 上会排出十列小图。540 宽时为 6 / 8 / 4、4 列。
    local pad_x = math.max(2, math.floor(w * 0.0112))
    local gap_v = math.max(2, math.floor(w * 0.015))
    local gap_h = math.max(1, math.floor(w * 0.0075))
    local target_w = math.floor(w * 0.26)
    local inner_w = w - pad_x * 2
    local cols = math.max(1, math.floor((inner_w + gap_h) / (target_w + gap_h) + 0.5))
    local poster_w = math.floor((inner_w - gap_h * (cols - 1)) / cols)
    local poster_h = math.floor(poster_w * 1.5)
    local lift = math.floor(poster_h * 0.5)
    local row_step = poster_h + gap_v
    local blocks = {}
    for col = 0, cols - 1 do
        local top = col % 2 == 0 and -lift or 0
        for row = 0, math.ceil((h - top) / row_step) - 1 do
            blocks[#blocks + 1] = U.coverBlock(shelf[#blocks % #shelf + 1],
                pad_x + col * (poster_w + gap_h), top + row * row_step, poster_w, poster_h)
        end
    end
    return blocks
end

--- 对齐网格：cols 列 2:3 封面按宽铺满 w×h，行数向上取整、上下均分溢出；书不够循环补位。
---@param shelf table[]
---@param cols number
---@return table[]
local function grid(shelf, cols, w, h)
    local gap = math.max(3, math.floor(w * 0.008))
    local cell_w = math.floor((w - gap * (cols - 1)) / cols)
    local cell_h = math.floor(cell_w * 1.5)
    local rows = math.ceil((h + gap) / (cell_h + gap))
    local left = math.floor((w - (cols * (cell_w + gap) - gap)) / 2)
    local top = math.floor((h - (rows * (cell_h + gap) - gap)) / 2)
    local blocks = {}
    for i = 0, cols * rows - 1 do
        local col, row = i % cols, math.floor(i / cols)
        blocks[#blocks + 1] = U.coverBlock(shelf[i % #shelf + 1],
            left + col * (cell_w + gap), top + row * (cell_h + gap), cell_w, cell_h)
    end
    return blocks
end

-- 剪切按行/列整段 blit；blitFrom 自己裁掉两侧越界，源图外的部分保持 dst 白底。
-- 偏移是实数：整数部分直接贴，小数部分 f 再把下一像素按 f 混进来（addblitFrom：dst·(1-f) + src·f），
-- 即 Paeth 的线性插值剪切；只取整的话三次剪切后斜边全是阶梯锯齿。

--- 水平剪切：dst(x, y) = src(x - k·y)，坐标以各自中心为原点。
local function shearX(dst, ox, oy, dw, dh, src, k)
    local sw, sh = src:getWidth(), src:getHeight()
    for row = 0, dh - 1 do
        local yc = row - dh / 2 + 0.5
        local offset = sw / 2 - dw / 2 - k * yc
        local sx, f = math.floor(offset), offset % 1
        local sy = math.floor(sh / 2 + yc)
        dst:blitFrom(src, ox, oy + row, sx, sy, dw, 1)
        if f > 0 then dst:addblitFrom(src, ox, oy + row, sx + 1, sy, dw, 1, f) end
    end
end

--- 垂直剪切：dst(x, y) = src(x, y - k·x)。
local function shearY(dst, ox, oy, dw, dh, src, k)
    local sw, sh = src:getWidth(), src:getHeight()
    for col = 0, dw - 1 do
        local xc = col - dw / 2 + 0.5
        local offset = sh / 2 - dh / 2 - k * xc
        local sx, sy, f = math.floor(sw / 2 + xc), math.floor(offset), offset % 1
        dst:blitFrom(src, ox + col, oy, sx, sy, 1, dh)
        if f > 0 then dst:addblitFrom(src, ox + col, oy, sx, sy + 1, 1, dh, f) end
    end
end

--- 把 src 绕中心旋转 angle（屏幕坐标，正值顺时针）贴到 dst 的 w×h 区域。
--- Paeth 三次剪切 Sx(α)·Sy(β)·Sx(α)，α=-tan(θ/2)、β=sin θ；中间图尺寸由输出反推，
--- 调用方的 src 必须至少有 M.slantSourceSize 那么大，且与 dst 同类型：
--- C 版 addblitFrom 遇到类型不同的两张图直接 exit(1)（灰度 Kindle 上 dst 是 BB8）。
---@param dst BlitBuffer
---@param src BlitBuffer 旋转后释放
function M.rotateInto(dst, x, y, w, h, src, angle)
    local Blitbuffer = require("ffi/blitbuffer")
    local alpha, beta = -math.tan(angle / 2), math.sin(angle)
    local a2 = math.ceil(w / 2 + math.abs(alpha) * h / 2)
    local b1 = math.ceil(h / 2 + math.abs(beta) * a2)
    ---@type BlitBuffer
    ---@diagnostic disable-next-line: assign-type-mismatch
    local mid = Blitbuffer.new(a2 * 2, b1 * 2, dst:getType())
    mid:fill(Blitbuffer.COLOR_WHITE)
    shearX(mid, 0, 0, a2 * 2, b1 * 2, src, alpha)
    src:free()
    ---@type BlitBuffer
    ---@diagnostic disable-next-line: assign-type-mismatch
    local last = Blitbuffer.new(a2 * 2, h, dst:getType())
    last:fill(Blitbuffer.COLOR_WHITE)
    shearY(last, 0, 0, a2 * 2, h, mid, beta)
    mid:free()
    shearX(dst, x, y, w, h, last, alpha)
    last:free()
end

--- 输出 w×h 旋转 angle 时，第一次剪切前的源图至少要多大。
---@return number, number
function M.slantSourceSize(w, h, angle)
    local alpha, beta = math.abs(math.tan(angle / 2)), math.abs(math.sin(angle))
    local a2 = math.ceil(w / 2 + alpha * h / 2)
    local b1 = math.ceil(h / 2 + beta * a2)
    return math.ceil(a2 + alpha * b1) * 2, b1 * 2
end

--- 倾斜网格：封面先画进离屏图，再整面旋转贴上。
---@param shelf table[]
---@return table[]
local function slanted(shelf, w, h, angle)
    local Blitbuffer = require("ffi/blitbuffer")
    local sw, sh = M.slantSourceSize(w, h, angle)
    local gap = math.max(3, math.floor(w * 0.008))
    local cell_w = (w - gap * 3) / 4
    local covers = grid(shelf, math.max(1, math.ceil(sw / (cell_w + gap))), sw, sh)
    local wall = {}
    function wall:getSize() return { w = w, h = h } end
    function wall:paintTo(bb, x, y)
        ---@type BlitBuffer
        ---@diagnostic disable-next-line: assign-type-mismatch
        local src = Blitbuffer.new(sw, sh, bb:getType())
        src:fill(Blitbuffer.COLOR_WHITE)
        local Canvas = require("features.lockscreen.render")
        for _idx, block in ipairs(covers) do Canvas.paintBlock(src, block, sw, sh) end
        M.rotateInto(bb, x, y, w, h, src, angle)
    end
    function wall:free()
        for _idx, block in ipairs(covers) do
            if block.widget then block.widget:free() end
        end
    end
    return {{ kind = "widget", widget = wall, x = 0, y = 0, width = w, height = h }}
end

local STYLES = {
    { id = "standard", label = _("标准布局"), layout = function(shelf, w, h) return grid(shelf, 4, w, h) end },
    { id = "slant_left", label = _("左斜边"), layout = function(shelf, w, h) return slanted(shelf, w, h, -SLANT) end },
    { id = "slant_right", label = _("右斜边"), layout = function(shelf, w, h) return slanted(shelf, w, h, SLANT) end },
    { id = "vertical", label = _("竖屏排版"), layout = staggered },
}

local STYLE_BY_ID = {}
for _idx, style in ipairs(STYLES) do STYLE_BY_ID[style.id] = style end

--- 风格是否合法。
---@param style string|nil
---@return boolean
function M.validStyle(style)
    return STYLE_BY_ID[style] ~= nil
end

--- 当前风格；未设置或非法时按竖屏排版（升级前的唯一样式）。
---@return string
function M.style()
    local style = MoonSettings.get("features.lockscreen").lock_screen_poster_style
    return STYLE_BY_ID[style] and style or DEFAULT_STYLE
end

--- 排序是否合法。
---@param sort string|nil
---@return boolean
function M.validSort(sort)
    return SORT_BY_ID[sort] ~= nil
end

--- 当前排序；未设置或非法时按最近阅读（升级前：recentBooks 优先）。
---@return string
function M.sort()
    local sort = MoonSettings.get("features.lockscreen").lock_screen_poster_sort
    return SORT_BY_ID[sort] and sort or DEFAULT_SORT
end

local SHELF_LIMIT = 128

--- 风格、排序、书单或封面到位情况变化才重画；书单摘要成 md5，免得把上百个 id 写进设置。
--- 仍有「带远程地址但本地没有」的封面时附带 lock_cycles：唤醒后 cache 失效才会再合成，
--- 不然占位海报能挂很多天。纯本地永远没封面的书不绑次数，避免每次唤醒整屏重画。
---@return string
function M.cache_key()
    local parts = {}
    local retryable = 0
    local shelf = books(SHELF_LIMIT)
    -- 没开过的网络书本地没封面：联网时后台补下载，落盘后键变化，下次锁屏重画。
    require("features.lockscreen.components.cover_prefetch").run(shelf)
    for _idx, book in ipairs(shelf) do
        if book.cover then
            parts[#parts + 1] = (book.source_id or "") .. "\0" .. book.stable_id .. "+"
        else
            parts[#parts + 1] = (book.source_id or "") .. "\0" .. book.stable_id .. "-"
            if book.cover_url then
                retryable = retryable + 1
            end
        end
    end
    local key = M.style() .. ":" .. M.sort() .. ":" .. require("ffi/sha2").md5(table.concat(parts, "\n"))
    return key .. require("features.lockscreen.cycle").pending(retryable > 0)
end

--- 风格的设置页选项。
---@return {text: string, value: string}[]
function M.styleOptions()
    local options = {}
    for _idx, style in ipairs(STYLES) do
        options[#options + 1] = { text = style.label, value = style.id }
    end
    return options
end

--- 风格显示名。
---@param style string|nil
---@return string
function M.styleLabel(style)
    return (STYLE_BY_ID[style] or STYLE_BY_ID[DEFAULT_STYLE]).label
end

--- 排序的设置页选项。
---@return {text: string, value: string}[]
function M.sortOptions()
    local options = {}
    for _idx, sort in ipairs(SORTS) do
        options[#options + 1] = { text = sort.label, value = sort.id }
    end
    return options
end

--- 排序显示名。
---@param sort string|nil
---@return string
function M.sortLabel(sort)
    return (SORT_BY_ID[sort] or SORT_BY_ID[DEFAULT_SORT]).label
end

--- 全屏海报墙；书库为空时明确显示空态，不能伪装成普通壁纸。
---@param rect table 全屏矩形
---@return table[]
function M.blocks(rect)
    local w = math.max(1, tonumber(rect.w) or 1)
    local h = math.max(1, tonumber(rect.h) or 1)
    local shelf = books(SHELF_LIMIT)
    if #shelf == 0 then
        return {{
            text = _("书库暂无书籍"),
            x = math.floor(w * 0.1), y = math.floor(h * 0.47),
            width = math.floor(w * 0.8), size = 22,
            bold = true, align = "center", box = false,
        }}
    end
    return STYLE_BY_ID[M.style()].layout(shelf, w, h)
end

return M
