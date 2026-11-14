--[[--
阅读页顶栏 / 底栏布局。

有序列表：`{ { id, align }, ... }`。不在列表里的组件就是关。
替代系统栏默认开，和现在的 overlay 行为一致。

@module koplugin.book.features.bars.layout
--]]

local MoonSettings = require("utils.settings")

local Layout = {}

local KEY = {
    top = "book_reader_top_bar_layout",
    bottom = "book_reader_bottom_bar_layout",
}

local REPLACE_KEY = {
    top = "book_reader_replace_top_bar",
    bottom = "book_reader_replace_bottom_bar",
}

local PERCENT_DECIMALS_KEY = "book_reader_percent_decimals"

local SETTING_DEFAULTS = require("features.bars.setting").defaults
local DEFAULTS = {
    top = SETTING_DEFAULTS.book_reader_top_bar_layout,
    bottom = SETTING_DEFAULTS.book_reader_bottom_bar_layout,
}

local DEFAULT_ALIGN = {
    chapter = "left",
    title = "left",
    page = "left",
    percent = "right",
    chapter_idx = "right",
    chapter_page = "right",
    remaining = "right",
    clock = "right",
    battery = "right",
    wifi = "right",
    brightness = "right",
    memory = "right",
    progress_bar = "left",
}

--- 拷贝布局表，避免把默认表交出去被改。
---@param layout table
---@return table
local function copyLayout(layout)
    local out = {}
    for i = 1, #layout do
        local item = layout[i]
        out[i] = { id = item.id, align = item.align, row = item.row }
    end
    return out
end

--- 该栏允许的组件 id。
---@param which string "top"|"bottom"
---@return table<string, boolean>
local function allowedIds(which)
    local Items = require("features.bars.items")
    local allowed = {}
    for _idx, item in ipairs(Items.catalog(which)) do
        allowed[item.id] = true
    end
    return allowed
end

--- align 只认 left / center / right，其它一律当 left。
---@param align any
---@return string
local function normalizeAlign(align)
    if align == "center" or align == "right" then
        return align
    end
    return "left"
end

--- 底栏双栏行归属：up 上行 / down 下行。其它值或缺失当上行。
---@param row any
---@return string
local function normalizeRow(row)
    if row == "down" then
        return "down"
    end
    return "up"
end

--- 原表是否已经写过行归属（有则不再按旧双栏习惯把进度条迁到下行）。
---@param raw table
---@return boolean
local function rawHasRow(raw)
    for i = 1, #raw do
        local item = raw[i]
        if type(item) == "table" and (item.row == "up" or item.row == "down") then
            return true
        end
    end
    return false
end

--- 清洗用户布局：已知 id、不重复、align 只有 left/center/right；底栏保留行归属。
---@param which string
---@return table
local function sanitize(which, raw)
    if type(raw) ~= "table" then raw = DEFAULTS[which] end
    local allowed = allowedIds(which)
    local seen, out = {}, {}
    -- 单栏只忽略行归属，不改变它；旧布局的缺省行必须与当前单双栏开关无关。
    local migrate_bar_down = which == "bottom" and not rawHasRow(raw)
    for i = 1, #raw do
        local item = raw[i]
        local id = type(item) == "table" and item.id or nil
        if id and allowed[id] and not seen[id] then
            local row = normalizeRow(item.row)
            if migrate_bar_down and id == "progress_bar" then
                row = "down"
            end
            out[#out + 1] = { id = id, align = normalizeAlign(item.align), row = row }
            seen[id] = true
        end
    end
    -- 空列表是用户明确关闭全部组件，不应被当成损坏配置。
    if #out == 0 and #raw > 0 then
        return sanitize(which, DEFAULTS[which])
    end
    return out
end

--- 按落盘原表缓存清洗结果；绘制热路径每帧都读，原表换了（Layout.set）才重洗。
---@type table<string, { raw: table|nil, layout: table }>
local cleaned = {}

--- 当前布局；返回共享表，调用方只读，要改先 copyLayout。
---@param which string
---@return table
function Layout.get(which)
    local raw = MoonSettings.get("features.bars")[KEY[which]]
    local hit = cleaned[which]
    if not hit or hit.raw ~= raw then
        hit = { raw = raw, layout = sanitize(which, raw) }
        cleaned[which] = hit
    end
    return hit.layout
end

--- 写入布局。
---@param which string
---@param layout table
function Layout.set(which, layout)
    local bars = MoonSettings.get("features.bars")
    bars[KEY[which]] = sanitize(which, layout)
    MoonSettings.save("features.bars", bars)
end

--- 是否用月读栏盖住系统栏。
---@param which string
---@return boolean
function Layout.replace(which)
    return MoonSettings.get("features.bars")[REPLACE_KEY[which]]
end

--- 写入替代系统栏开关。
---@param which string
---@param on boolean
function Layout.setReplace(which, on)
    local bars = MoonSettings.get("features.bars")
    bars[REPLACE_KEY[which]] = on ~= false
    MoonSettings.save("features.bars", bars)
end

--- 组件是否带图标（顶栏、底栏共用）。
---@return boolean
function Layout.icons()
    return MoonSettings.get("features.bars").book_reader_bar_icons
end

---@param on boolean
function Layout.setIcons(on)
    local bars = MoonSettings.get("features.bars")
    bars.book_reader_bar_icons = on
    MoonSettings.save("features.bars", bars)
end

--- 总进度是否显示两位小数。
---@return boolean
function Layout.percentDecimals()
    return MoonSettings.get("features.bars")[PERCENT_DECIMALS_KEY] == true
end

---@param on boolean
function Layout.setPercentDecimals(on)
    local bars = MoonSettings.get("features.bars")
    bars[PERCENT_DECIMALS_KEY] = on
    MoonSettings.save("features.bars", bars)
end

local DIVIDER_KEY = { top = "book_reader_top_bar_divider", bottom = "book_reader_bottom_bar_divider" }

--- 栏与正文之间是否画分割线。
---@param which string "top"|"bottom"
---@return boolean
function Layout.divider(which)
    return MoonSettings.get("features.bars")[DIVIDER_KEY[which]]
end

---@param which string
---@param on boolean
function Layout.setDivider(which, on)
    local bars = MoonSettings.get("features.bars")
    bars[DIVIDER_KEY[which]] = on
    MoonSettings.save("features.bars", bars)
end

--- 文字字号范围与缺省（与 KOReader 状态栏「Item font size」一致，未缩放的 pt）。
Layout.FONT_MIN, Layout.FONT_MAX, Layout.FONT_DEFAULT = 8, 36, 14
--- 顶栏比 CRE 原生页头额外增加的高度范围与缺省（未缩放像素）。
Layout.TOP_HEIGHT_MIN, Layout.TOP_HEIGHT_MAX, Layout.TOP_HEIGHT_DEFAULT = 0, 60, 12
--- 顶栏 / 底栏 / 预览共用的水平留白（未缩放），不跟书籍页边距或 ReaderFooter 进度条边距变化。
Layout.BAR_HORIZONTAL_PADDING = 12
--- 进度条粗细（未缩放像素）。未设置时绘制走主题高度；设置页用 Spin，与字号 / 高度同一套缩放。
Layout.BAR_THICKNESS_MIN, Layout.BAR_THICKNESS_MAX = 1, 24
--- 双栏时信息行与进度条之间的间隙（未缩放）。
Layout.STACK_GAP = 2

local FONT_KEY = { top = "book_reader_top_font_size", bottom = "book_reader_bottom_font_size" }

---@param v any
---@param min number
---@param max number
---@return number|nil
local function clampInt(v, min, max)
    v = tonumber(v)
    if not v then return nil end
    return math.max(min, math.min(max, math.floor(v)))
end

--- 文字字号。底栏以 KOReader 状态栏为准（两边同一份）；顶栏用自己的值，未设置时跟随底栏。
---@param which string
---@param footer_settings table|nil KOReader ReaderFooter.settings
---@return number
function Layout.fontSize(which, footer_settings)
    local bars = MoonSettings.get("features.bars")
    local footer = footer_settings and clampInt(footer_settings.text_font_size, Layout.FONT_MIN, Layout.FONT_MAX)
    local own = clampInt(bars[FONT_KEY[which]], Layout.FONT_MIN, Layout.FONT_MAX)
    if which == "top" then
        return own or footer or Layout.FONT_DEFAULT
    end
    return footer or own or Layout.FONT_DEFAULT
end

--- 顶栏是否设置了自己的字号（否则跟随底栏）。
---@return boolean
function Layout.topFontCustom()
    return MoonSettings.get("features.bars")[FONT_KEY.top] ~= nil
end

--- 写入字号；nil 清除（顶栏恢复跟随底栏）。
---@param which string
---@param size number|nil
function Layout.setFontSize(which, size)
    local bars = MoonSettings.get("features.bars")
    bars[FONT_KEY[which]] = size and clampInt(size, Layout.FONT_MIN, Layout.FONT_MAX) or nil
    MoonSettings.save("features.bars", bars)
end

--- 顶栏额外高度（未缩放像素）。
---@return number
function Layout.topHeight()
    return clampInt(MoonSettings.get("features.bars").book_reader_top_bar_height,
        Layout.TOP_HEIGHT_MIN, Layout.TOP_HEIGHT_MAX) or Layout.TOP_HEIGHT_DEFAULT
end

---@param v number
function Layout.setTopHeight(v)
    local bars = MoonSettings.get("features.bars")
    bars.book_reader_top_bar_height = clampInt(v, Layout.TOP_HEIGHT_MIN, Layout.TOP_HEIGHT_MAX)
    MoonSettings.save("features.bars", bars)
end

--- 顶栏离屏幕顶部的边距（未缩放像素）。靠文档顶部页边距预留空间，正文随之下移，见 Bars.syncTopMargin。
Layout.TOP_MARGIN_MIN, Layout.TOP_MARGIN_MAX, Layout.TOP_MARGIN_DEFAULT = 0, 60, 0
--- 底栏离屏幕底部的边距：就是 KOReader 状态栏「Bottom margin」（container_bottom_padding），范围与缺省同它。
Layout.BOTTOM_MARGIN_MIN, Layout.BOTTOM_MARGIN_MAX, Layout.BOTTOM_MARGIN_DEFAULT = 0, 49, 1

---@return number
function Layout.topMargin()
    return clampInt(MoonSettings.get("features.bars").book_reader_top_bar_margin,
        Layout.TOP_MARGIN_MIN, Layout.TOP_MARGIN_MAX) or Layout.TOP_MARGIN_DEFAULT
end

---@param v number
function Layout.setTopMargin(v)
    local bars = MoonSettings.get("features.bars")
    bars.book_reader_top_bar_margin = clampInt(v, Layout.TOP_MARGIN_MIN, Layout.TOP_MARGIN_MAX)
    MoonSettings.save("features.bars", bars)
end

---@param footer_settings table|nil KOReader ReaderFooter.settings
---@return number
function Layout.bottomMargin(footer_settings)
    return footer_settings
        and clampInt(footer_settings.container_bottom_padding, Layout.BOTTOM_MARGIN_MIN, Layout.BOTTOM_MARGIN_MAX)
        or Layout.BOTTOM_MARGIN_DEFAULT
end

local THICKNESS_KEY = "book_reader_progress_thickness"

--- 用户设置的进度条粗细（未缩放）；未设置返回 nil，绘制时回落到主题高度。
---@return number|nil
function Layout.progressThickness()
    return clampInt(MoonSettings.get("features.bars")[THICKNESS_KEY],
        Layout.BAR_THICKNESS_MIN, Layout.BAR_THICKNESS_MAX)
end

--- 写入粗细；nil 清除，恢复跟随主题。
---@param v number|nil
function Layout.setProgressThickness(v)
    local bars = MoonSettings.get("features.bars")
    bars[THICKNESS_KEY] = v and clampInt(v, Layout.BAR_THICKNESS_MIN, Layout.BAR_THICKNESS_MAX) or nil
    MoonSettings.save("features.bars", bars)
end

--- 绘制用的进度条高度（已缩放像素）。有用户值时按 scaleBySize，否则用主题 progress.height。
---@return number
function Layout.progressBarHeight()
    local own = Layout.progressThickness()
    local Screen = require("device").screen
    if own then
        return math.max(1, Screen:scaleBySize(own))
    end
    return math.max(1, Screen:scaleBySize(Layout.themeProgressThickness()))
end

--- 主题声明的进度条粗细（未缩放）。设置页展示「跟随主题」用。
---@return number
function Layout.themeProgressThickness()
    return require("ui.themes").current().progress.height
end

local STACKED_KEY = "book_reader_bottom_bar_stacked"

--- 用户是否选择了底栏双栏。未设置或 false 为单栏（旧配置默认，不随居中自动拆行）。
---@return boolean
function Layout.stackedPreferred()
    return MoonSettings.get("features.bars")[STACKED_KEY] == true
end

--- 写入底栏单栏 / 双栏；false 或 nil 都当单栏。不改 KOReader 的 container_height。
---@param on boolean
function Layout.setStacked(on)
    local bars = MoonSettings.get("features.bars")
    bars[STACKED_KEY] = on and true or false
    MoonSettings.save("features.bars", bars)
end

--- 组件的双栏行归属。
---@param item table
---@return string "up"|"down"
function Layout.itemRow(item)
    if item and item.row == "down" then
        return "down"
    end
    return "up"
end

--- 按行拆开布局，保留各行原有顺序。单栏调用方应忽略行归属、把全部项当一行。
---@param layout table|nil
---@return table up
---@return table down
function Layout.partition(layout)
    layout = layout or Layout.get("bottom")
    local up, down = {}, {}
    for i = 1, #layout do
        if Layout.itemRow(layout[i]) == "down" then
            down[#down + 1] = layout[i]
        else
            up[#up + 1] = layout[i]
        end
    end
    return up, down
end

--- 实际要画的行（空行丢掉）。未开双栏时全部在一行；开了双栏但只有一行有组件时也只返回一行。
---@param layout table|nil
---@param stacked boolean|nil
---@return table[]
function Layout.effectiveRows(layout, stacked)
    layout = layout or Layout.get("bottom")
    if stacked == nil then stacked = Layout.stackedPreferred() end
    if not stacked then
        if #layout == 0 then return {} end
        return { layout }
    end
    local up, down = Layout.partition(layout)
    local rows = {}
    if #up > 0 then rows[#rows + 1] = up end
    if #down > 0 then rows[#rows + 1] = down end
    return rows
end

--- 底栏是否实际画成两行：开了双栏，并且上下行都有启用的组件。不特判进度条或居中。
---@param layout table|nil
---@return boolean
function Layout.stackedBottom(layout)
    return #Layout.effectiveRows(layout) >= 2
end

--- 底栏实际内容总高（已缩放）：与绘制共用真实字体行高。
---@param footer_settings table|nil
---@param font_size number|nil
---@param layout table|nil
---@return number
function Layout.bottomPaintHeight(footer_settings, font_size, layout)
    local Screen = require("device").screen
    local rows = Layout.effectiveRows(layout)
    local face = require("ui/font"):getFace("ffont", font_size or Layout.fontSize("bottom", footer_settings))
    local Items = require("features.bars.items")
    local icons, bar_h = Layout.icons(), Layout.progressBarHeight()
    local h = 0
    for i = 1, #rows do
        if i > 1 then
            h = h + Screen:scaleBySize(Layout.STACK_GAP)
        end
        h = h + Items.rowHeight(rows[i], face, icons, bar_h)
    end
    return h
end

--- 组件在布局里的下标；不在返回 nil。
---@param layout table
---@param id string
---@return integer|nil
local function indexOf(layout, id)
    for i = 1, #layout do
        if layout[i].id == id then
            return i
        end
    end
end

--- 栏里已启用的组件按布局顺序，未启用的按目录顺序跟在后面（旧配置顺序保留，不丢项）。
---@param which string
---@return BookReaderBarItem[]
function Layout.orderedCatalog(which)
    local catalog = require("features.bars.items").catalog(which)
    local by_id = {}
    for i = 1, #catalog do
        by_id[catalog[i].id] = catalog[i]
    end
    local out = {}
    local layout = Layout.get(which)
    for i = 1, #layout do
        local item = by_id[layout[i].id]
        if item then
            out[#out + 1] = item
            by_id[layout[i].id] = nil
        end
    end
    for i = 1, #catalog do
        if by_id[catalog[i].id] then
            out[#out + 1] = by_id[catalog[i].id]
        end
    end
    return out
end

--- 组件位置、对齐与行归属；未启用返回 nil。
---@param which string
---@param id string
---@return number|nil index
---@return string|nil align
---@return string|nil row
function Layout.slot(which, id)
    local layout = Layout.get(which)
    local index = indexOf(layout, id)
    if not index then
        return nil, nil
    end
    return index, layout[index].align, Layout.itemRow(layout[index])
end

--- 开关组件：打开时追加到末尾；再次启用默认上行（与原先丢对齐一样不恢复旧行归属）。
---@param which string
---@param id string
function Layout.toggle(which, id)
    local layout = copyLayout(Layout.get(which))
    local index = indexOf(layout, id)
    if index then
        table.remove(layout, index)
        Layout.set(which, layout)
        return
    end
    if not allowedIds(which)[id] then
        return
    end
    layout[#layout + 1] = { id = id, align = DEFAULT_ALIGN[id] or "left", row = "up" }
    Layout.set(which, layout)
end

--- 写入双栏行归属。单栏时也保存，切回双栏不丢。
---@param which string
---@param id string
---@param row string "up"|"down"
function Layout.setRow(which, id, row)
    if row ~= "up" and row ~= "down" then
        return
    end
    local layout = copyLayout(Layout.get(which))
    local index = indexOf(layout, id)
    if index then
        layout[index].row = row
        Layout.set(which, layout)
    end
end

--- 同属一行的启用组件里，该项的位置与该行数量；不在布局里返回 nil。
---@param which string
---@param id string
---@return number|nil index
---@return number|nil count
---@return string|nil row
function Layout.rowPosition(which, id)
    local layout = Layout.get(which)
    local index = indexOf(layout, id)
    if not index then
        return nil, nil, nil
    end
    local row = Layout.itemRow(layout[index])
    local pos, count = 0, 0
    for i = 1, #layout do
        if Layout.itemRow(layout[i]) == row then
            count = count + 1
            if i == index then pos = count end
        end
    end
    return pos, count, row
end

--- 同栏内移动 delta 位，越界截断到首尾。
---@param which string
---@param id string
---@param delta number
function Layout.move(which, id, delta)
    local layout = copyLayout(Layout.get(which))
    local index = indexOf(layout, id)
    if not index then
        return
    end
    local target = math.max(1, math.min(#layout, index + delta))
    if target == index then
        return
    end
    table.insert(layout, target, table.remove(layout, index))
    Layout.set(which, layout)
end

--- 只在同一行内移动（双栏上下行各自排序）。越界不绕到另一行。
---@param which string
---@param id string
---@param delta number
function Layout.moveInRow(which, id, delta)
    local layout = copyLayout(Layout.get(which))
    local index = indexOf(layout, id)
    if not index then
        return
    end
    local row = Layout.itemRow(layout[index])
    local idxs = {}
    for i = 1, #layout do
        if Layout.itemRow(layout[i]) == row then
            idxs[#idxs + 1] = i
        end
    end
    local pos
    for j = 1, #idxs do
        if idxs[j] == index then
            pos = j
            break
        end
    end
    local dest = pos and (pos + delta) or 0
    if dest < 1 or dest > #idxs then
        return
    end
    local a, b = idxs[pos], idxs[dest]
    layout[a], layout[b] = layout[b], layout[a]
    Layout.set(which, layout)
end

--- 改对齐：left / center / right。
---@param which string
---@param id string
---@param align string
function Layout.setAlign(which, id, align)
    if align ~= "left" and align ~= "center" and align ~= "right" then
        return
    end
    local layout = copyLayout(Layout.get(which))
    local index = indexOf(layout, id)
    if index then
        layout[index].align = align
        Layout.set(which, layout)
    end
end

return Layout
