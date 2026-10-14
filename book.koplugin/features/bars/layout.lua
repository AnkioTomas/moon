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
    progress_bar = "left",
}

--- 拷贝布局表，避免把默认表交出去被改。
---@param layout table
---@return table
local function copyLayout(layout)
    local out = {}
    for i = 1, #layout do
        local item = layout[i]
        out[i] = { id = item.id, align = item.align }
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

--- 清洗用户布局：已知 id、不重复、align 只有 left/right。
---@param which string
---@return table
local function sanitize(which, raw)
    if type(raw) ~= "table" then
        return copyLayout(DEFAULTS[which])
    end
    local allowed = allowedIds(which)
    local seen, out = {}, {}
    for i = 1, #raw do
        local item = raw[i]
        local id = type(item) == "table" and item.id or nil
        if id and allowed[id] and not seen[id] then
            local align = item.align == "right" and "right" or "left"
            out[#out + 1] = { id = id, align = align }
            seen[id] = true
        end
    end
    -- 空列表是用户明确关闭全部组件，不应被当成损坏配置。
    if #out == 0 and #raw > 0 then
        return copyLayout(DEFAULTS[which])
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

--- 文字字号范围与缺省（与 KOReader 状态栏「Item font size」一致，未缩放的 pt）。
Layout.FONT_MIN, Layout.FONT_MAX, Layout.FONT_DEFAULT = 8, 36, 14
--- 顶栏比 CRE 原生页头额外增加的高度范围与缺省（未缩放像素）。
Layout.TOP_HEIGHT_MIN, Layout.TOP_HEIGHT_MAX, Layout.TOP_HEIGHT_DEFAULT = 0, 60, 12
--- 顶栏 / 底栏 / 预览共用的水平留白（未缩放），不跟书籍页边距或 ReaderFooter 进度条边距变化。
Layout.BAR_HORIZONTAL_PADDING = 12

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

--- 组件位置与对齐；未启用返回 nil。
---@param which string
---@param id string
---@return number|nil index
---@return string|nil align
function Layout.slot(which, id)
    local layout = Layout.get(which)
    local index = indexOf(layout, id)
    if not index then
        return nil, nil
    end
    return index, layout[index].align
end

--- 开关组件：打开时追加到末尾。
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
    layout[#layout + 1] = { id = id, align = DEFAULT_ALIGN[id] or "left" }
    Layout.set(which, layout)
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

--- 改左右对齐。
---@param which string
---@param id string
---@param align string
function Layout.setAlign(which, id, align)
    if align ~= "left" and align ~= "right" then
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
