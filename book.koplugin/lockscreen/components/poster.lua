--[[--
锁屏主体：海报墙。

风格：
- vertical（竖屏排版，默认）：错层墙，单数列整体上移半张海报（可探出顶边），
  双数列顶边对齐；列宽均分铺满宽度，固定行距排到盖住屏幕底。
- standard：2:3 封面 4 列整齐对齐、按宽铺满，多出的高度上下均分裁掉。
- slant_left / slant_right：标准网格整面倾斜；先画进离屏大图，再三次剪切旋转贴到画布。
所有风格都铺满整屏，书不够时循环补位。

@module koplugin.book.lockscreen.components.poster
--]]

local BookDB = require("db.book")
local Catalog = require("book.catalog")
local Library = require("lockscreen.components.library")
local MoonSettings = require("utils.settings")
local _ = require("gettext")

local UI
local BookInfo

--- 延迟加载桌面同源组件，避免锁屏初始化依赖完整 UI 树。
local function ensureUI()
    if UI then return end
    UI = require("ui.components.bookui")
    BookInfo = require("ui.components.bookinfo")
end

local DEFAULT_STYLE = "vertical"
local SLANT = math.rad(12)

local M = {
    id = "poster",
    label = _("海报墙"),
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
    local result = {}
    local append = Library.shelfCollector(source_id)
    append(result, recent, limit)
    if #result < limit and (type(source_id) == "string" and source_id ~= "" or type(source_id) == "table" and #source_id > 0) then
        ---@cast source_id string|string[]
        local rows = select(1, BookDB.listBySource(source_id, {
            limit = limit * 2,
            offset = 0,
        }))
        append(result, rows, limit)
    end
    return result
end

--- 一张封面的绘制块。
---@param book table
---@return table
local function coverBlock(book, x, y, w, h)
    local widget = select(1, BookInfo.cover(nil, nil, book, w, h, { shadow = false }))
    return { kind = "widget", widget = widget, x = x, y = y, width = w, height = h }
end

--- 错层海报墙：列宽按目标尺寸均分铺满宽度，单数列上移半张探出顶边；
--- 每列排到盖住屏幕底为止，书不够循环补位。
---@param shelf table[]
---@return table[]
local function staggered(shelf, w, h)
    local pad_x = UI.sz(6)
    local gap_v = UI.sz(8)
    local gap_h = UI.sz(4)
    local target_w = math.max(UI.sz(100), math.min(UI.sz(128), math.floor(w * 0.26)))
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
            blocks[#blocks + 1] = coverBlock(shelf[#blocks % #shelf + 1],
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
    local gap = UI.sz(4)
    local cell_w = math.floor((w - gap * (cols - 1)) / cols)
    local cell_h = math.floor(cell_w * 1.5)
    local rows = math.ceil((h + gap) / (cell_h + gap))
    local left = math.floor((w - (cols * (cell_w + gap) - gap)) / 2)
    local top = math.floor((h - (rows * (cell_h + gap) - gap)) / 2)
    local blocks = {}
    for i = 0, cols * rows - 1 do
        local col, row = i % cols, math.floor(i / cols)
        blocks[#blocks + 1] = coverBlock(shelf[i % #shelf + 1],
            left + col * (cell_w + gap), top + row * (cell_h + gap), cell_w, cell_h)
    end
    return blocks
end

-- 剪切按行/列整段 blit；blitFrom 自己裁掉两侧越界，源图外的部分保持 dst 白底。

--- 水平剪切：dst(x, y) = src(x - k·y)，坐标以各自中心为原点。
local function shearX(dst, ox, oy, dw, dh, src, k)
    local sw, sh = src:getWidth(), src:getHeight()
    for row = 0, dh - 1 do
        local yc = row - dh / 2 + 0.5
        dst:blitFrom(src, ox, oy + row,
            math.floor(sw / 2 - dw / 2 - k * yc + 0.5), math.floor(sh / 2 + yc), dw, 1)
    end
end

--- 垂直剪切：dst(x, y) = src(x, y - k·x)。
local function shearY(dst, ox, oy, dw, dh, src, k)
    local sw, sh = src:getWidth(), src:getHeight()
    for col = 0, dw - 1 do
        local xc = col - dw / 2 + 0.5
        dst:blitFrom(src, ox + col, oy,
            math.floor(sw / 2 + xc), math.floor(sh / 2 - dh / 2 - k * xc + 0.5), 1, dh)
    end
end

--- 把 src 绕中心旋转 angle（屏幕坐标，正值顺时针）贴到 dst 的 w×h 区域。
--- Paeth 三次剪切 Sx(α)·Sy(β)·Sx(α)，α=-tan(θ/2)、β=sin θ；中间图尺寸由输出反推，
--- 调用方的 src 必须至少有 M.slantSourceSize 那么大。
---@param dst BlitBuffer
---@param src BlitBuffer 旋转后释放
function M.rotateInto(dst, x, y, w, h, src, angle)
    local Blitbuffer = require("ffi/blitbuffer")
    local alpha, beta = -math.tan(angle / 2), math.sin(angle)
    local a2 = math.ceil(w / 2 + math.abs(alpha) * h / 2)
    local b1 = math.ceil(h / 2 + math.abs(beta) * a2)
    local mid = Blitbuffer.new(a2 * 2, b1 * 2, Blitbuffer.TYPE_BBRGB32)
    mid:fill(Blitbuffer.COLOR_WHITE)
    shearX(mid, 0, 0, a2 * 2, b1 * 2, src, alpha)
    src:free()
    local last = Blitbuffer.new(a2 * 2, h, Blitbuffer.TYPE_BBRGB32)
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

--- 倾斜网格：封面挂在一个 widget 的数字子项上，Image.await 照常等它们落定。
---@param shelf table[]
---@return table[]
local function slanted(shelf, w, h, angle)
    local Blitbuffer = require("ffi/blitbuffer")
    local Canvas = require("ui.render")
    local sw, sh = M.slantSourceSize(w, h, angle)
    local cell_w = (w - UI.sz(4) * 3) / 4
    local covers = grid(shelf, math.max(1, math.ceil(sw / (cell_w + UI.sz(4)))), sw, sh)
    local wall = {}
    for i, block in ipairs(covers) do wall[i] = block.widget end
    function wall:getSize() return { w = w, h = h } end
    function wall:paintTo(bb, x, y)
        local src = Blitbuffer.new(sw, sh, Blitbuffer.TYPE_BBRGB32)
        src:fill(Blitbuffer.COLOR_WHITE)
        for _, block in ipairs(covers) do Canvas.paintWidget(src, block, sw, sh) end
        M.rotateInto(bb, x, y, w, h, src, angle)
    end
    function wall:free()
        for _, widget in ipairs(self) do
            if widget.free then widget:free() end
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
for _, style in ipairs(STYLES) do STYLE_BY_ID[style.id] = style end

--- 风格是否合法。
---@param style string|nil
---@return boolean
function M.validStyle(style)
    return STYLE_BY_ID[style] ~= nil
end

--- 当前风格；未设置或非法时按竖屏排版（升级前的唯一样式）。
---@return string
function M.style()
    local style = MoonSettings.get().lock_screen_poster_style
    return STYLE_BY_ID[style] and style or DEFAULT_STYLE
end
M.cache_key = M.style

--- 风格的设置页选项。
---@return {text: string, value: string}[]
function M.styleOptions()
    local options = {}
    for _, style in ipairs(STYLES) do
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

--- 全屏海报墙；书库为空时明确显示空态，不能伪装成普通壁纸。
---@param rect table 全屏矩形
---@return table[]
function M.blocks(rect)
    ensureUI()
    local w = math.max(1, tonumber(rect.w) or 1)
    local h = math.max(1, tonumber(rect.h) or 1)
    local shelf = books(128)
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
