--[[--
阅读页栏组件目录与绘制。

只认 ctx 里的字符串和数字，不碰桌面顶栏。
paint 是 ReaderView 热路径：文本与图标控件可缓存。

每个组件自带文案与图标：`text(ctx, icons)` 在开图标时返回更短的文案（图标已经说明了是什么），
`glyph` 是 Material Symbols 名或按 ctx 选名的函数（电量、Wi-Fi、亮度随状态换图标）；
没有 glyph 的组件（时钟、百分比）本身一眼可读，不配图标。`icon` 只给设置页行用。

@module koplugin.book.features.bars.items
--]]

require("l10n").apply()
local _ = require("gettext")

local Items = {}

---@class BookReaderBarItem
---@field id string
---@field label string
---@field icon string 设置页行图标
---@field top boolean|nil
---@field bottom boolean|nil
---@field flex boolean|nil
---@field kind string|nil "bar" 时画进度条
---@field text fun(ctx: table, icons: boolean|nil): string|nil
---@field glyph string|fun(ctx: table): string|nil|nil

---@param pct number|nil
---@return number
local function clampPercent(pct)
    pct = tonumber(pct) or 0
    if pct < 0 then
        return 0
    end
    if pct > 100 then
        return 100
    end
    return pct
end

---@param pct number
---@return string
local function percentText(pct)
    return string.format("%d%%", math.floor(clampPercent(pct) + 0.5))
end

--- 电量与充电状态；设置页预览的样例上下文直接给值。
---@param ctx table
---@return number|nil capacity
---@return boolean|nil charging
local function battery(ctx)
    if ctx.battery then
        return ctx.battery, ctx.charging
    end
    local Device = require("device")
    if not Device:hasBattery() then
        return nil
    end
    return Device.powerd:getCapacity(), Device.powerd:isCharging()
end

---@param ctx table
---@return boolean
local function wifiOn(ctx)
    if ctx.wifi ~= nil then
        return ctx.wifi
    end
    return require("ui/network/manager"):isWifiOn()
end

---@param ctx table
---@return number|nil
local function brightness(ctx)
    if ctx.brightness then
        return ctx.brightness
    end
    if not require("device"):hasFrontlight() then
        return nil
    end
    return require("features.panel.desktop").lightPercent("brightness")
end

--- 系统剩余运存（MB）；和桌面顶栏同源（KOReader util.calcFreeMem），读不到返回 nil。
---@param ctx table
---@return number|nil
local function freeMemory(ctx)
    if ctx.memory then
        return ctx.memory
    end
    local bytes = require("util").calcFreeMem()
    return bytes and bytes / 1024 / 1024 or nil
end

--- 「a/b」形式；开图标时省掉前后缀。
---@param a number|nil
---@param b number|nil
---@param plain string 不开图标时的格式，含两个 %d
---@param icons boolean|nil
---@return string
local function fraction(a, b, plain, icons)
    if not a or not b or b <= 0 then
        return ""
    end
    return string.format(icons and "%d/%d" or plain, a, b)
end

Items.CATALOG = {
    {
        id = "chapter", label = _("章节"), icon = "menu_book", top = true, bottom = true, flex = true,
        glyph = "menu_book",
        text = function(ctx) return ctx.chapter end,
    },
    {
        id = "title", label = _("书名"), icon = "book", top = true, bottom = true, flex = true,
        glyph = "book",
        text = function(ctx) return ctx.title end,
    },
    {
        id = "clock", label = _("时钟"), icon = "schedule", top = true, bottom = true,
        text = function(ctx) return ctx.clock end,
    },
    {
        id = "battery", label = _("电池"), icon = "battery_android_full", top = true, bottom = true,
        glyph = function(ctx)
            local capacity, charging = battery(ctx)
            if not capacity then return nil end
            if charging then return "battery_android_bolt" end
            if capacity >= 95 then return "battery_android_full" end
            return "battery_android_" .. math.floor(clampPercent(capacity) * 7 / 100)
        end,
        text = function(ctx)
            local capacity = battery(ctx)
            return capacity and percentText(capacity) or ""
        end,
    },
    {
        id = "wifi", label = _("Wi-Fi"), icon = "wifi", top = true, bottom = true,
        glyph = function(ctx) return wifiOn(ctx) and "wifi" or "wifi_off" end,
        text = function(ctx, icons)
            if icons then return "" end
            return wifiOn(ctx) and _("Wi-Fi") or _("离线")
        end,
    },
    {
        id = "brightness", label = _("亮度"), icon = "brightness_6", top = true, bottom = true,
        glyph = function(ctx)
            local level = brightness(ctx)
            if not level then return nil end
            if level < 34 then return "brightness_low" end
            if level < 67 then return "brightness_medium" end
            return "brightness_high"
        end,
        text = function(ctx)
            local level = brightness(ctx)
            return level and percentText(level) or ""
        end,
    },
    {
        id = "memory", label = _("剩余运存"), icon = "memory", top = true, bottom = true,
        glyph = function(ctx) return freeMemory(ctx) and "memory" or nil end,
        text = function(ctx, icons)
            local mb = freeMemory(ctx)
            if not mb then return "" end
            local value = mb >= 1024 and string.format("%.1fG", mb / 1024) or string.format("%dM", mb)
            return icons and value or _("运存") .. " " .. value
        end,
    },
    {
        id = "page", label = _("页码"), icon = "pin", top = true, bottom = true,
        glyph = "docs",
        -- 不省前缀：和章内页码都是 N/M，图标区分不开，第一章当前页本来就相同。
        text = function(ctx) return fraction(ctx.page, ctx.total_pages, _("全书 %d/%d")) end,
    },
    {
        id = "percent", label = _("进度"), icon = "percent", top = true, bottom = true,
        text = function(ctx)
            return string.format(ctx.percent_decimals and "%.2f%%" or "%.0f%%", clampPercent(ctx.percent))
        end,
    },
    {
        id = "chapter_idx", label = _("章节序号"), icon = "format_list_numbered", top = true, bottom = true,
        glyph = "toc",
        text = function(ctx, icons)
            return fraction(ctx.chapter_idx, ctx.chapter_count, _("第 %d/%d 章"), icons)
        end,
    },
    {
        id = "chapter_page", label = _("章内页码"), icon = "auto_stories", top = true, bottom = true,
        glyph = "auto_stories",
        text = function(ctx)
            return fraction(ctx.chapter_page, ctx.chapter_pages, _("本章 %d/%d"))
        end,
    },
    {
        id = "remaining", label = _("剩余时间"), icon = "hourglass_bottom", top = true, bottom = true,
        glyph = "hourglass_bottom",
        text = function(ctx) return ctx.remaining end,
    },
    {
        id = "progress_bar", label = _("进度条"), icon = "horizontal_rule", bottom = true, flex = true, kind = "bar",
        text = function() return "" end,
    },
}

local BY_ID = {}
for i = 1, #Items.CATALOG do
    BY_ID[Items.CATALOG[i].id] = Items.CATALOG[i]
end

--- 某栏可用的组件。
---@param which string|nil "top"|"bottom"|nil
---@return BookReaderBarItem[]
function Items.catalog(which)
    if not which then
        return Items.CATALOG
    end
    local out = {}
    for i = 1, #Items.CATALOG do
        local item = Items.CATALOG[i]
        if item[which] then
            out[#out + 1] = item
        end
    end
    return out
end

--- 设置页预览用的样例数据。
---@return table
function Items.sampleContext()
    return {
        chapter = _("第三章 初见"),
        title = _("示例书名"),
        clock = "12:34",
        percent = 42,
        percent_decimals = false,
        chapter_idx = 3,
        chapter_count = 10,
        page = 120,
        total_pages = 320,
        chapter_page = 5,
        chapter_pages = 18,
        remaining = _("约 30 分钟"),
        battery = 85,
        charging = false,
        wifi = true,
        brightness = 40,
        memory = 512,
    }
end

--- 组件文案；进度条返回空串。
---@param id string
---@param ctx table
---@param icons boolean|nil 开图标时返回省掉前后缀的短文案
---@return string
function Items.text(id, ctx, icons)
    return BY_ID[id].text(ctx, icons) or ""
end

--- 组件图标名；没有图标返回 nil。
---@param id string
---@param ctx table
---@return string|nil
function Items.glyph(id, ctx)
    local glyph = BY_ID[id].glyph
    if type(glyph) == "function" then
        return glyph(ctx)
    end
    return glyph
end

local font_heights = setmetatable({}, { __mode = "k" })

local function fontHeight(face)
    local height = font_heights[face]
    if not height then
        local widget = require("ui/widget/textwidget"):new{ text = "", face = face }
        height = widget:getSize().h
        widget:free()
        font_heights[face] = height
    end
    return height
end

--- 容器预留与实际绘制使用同一份字体度量，包含 TextWidget 自带的 padding。
---@param row table[]
---@param face table
---@param icons boolean|nil
---@param bar_h number
---@return number
function Items.rowHeight(row, face, icons, bar_h)
    local height = 1
    for i = 1, #row do
        local meta = BY_ID[row[i].id]
        if meta.kind == "bar" then
            height = math.max(height, bar_h)
        else
            height = math.max(height, fontHeight(face))
            if icons and meta.glyph then
                local icon_face = require("ui.themes.widgets.icon").face(face.orig_size)
                height = math.max(height, fontHeight(icon_face))
            end
        end
    end
    return height
end

---@param slot string
---@param key string
---@param opts table
---@param cache table|nil
---@return table
local function cachedTextWidget(slot, key, opts, cache)
    local TextWidget = require("ui/widget/textwidget")
    if not cache then
        return TextWidget:new(opts)
    end
    local widget = cache.widgets[slot]
    if not widget or cache.keys[slot] ~= key then
        if widget and widget.free then
            widget:free()
        end
        widget = TextWidget:new(opts)
        cache.widgets[slot] = widget
        cache.keys[slot] = key
    end
    return widget
end

---@param widget table
---@param px number
---@param band_y number
---@param band_h number
local function paintCentered(widget, bb, px, band_y, band_h)
    local sz = widget:getSize()
    widget:paintTo(bb, px, band_y + math.floor((band_h - sz.h) / 2))
end

--- 按左右对齐把布局画进条带。
---@param x number
---@param y number
---@param w number
---@param h number
---@param layout table
---@param ctx table
---@param opts { face: table, fgcolor: table|nil, cache: table|nil, prefix: string|nil, gap: number|nil, bar_h: number|nil, icons: boolean|nil, stacked: boolean|nil, stack_gap: number|nil }
function Items.paint(bb, x, y, w, h, layout, ctx, opts)
    local Device = require("device")
    local Screen = Device.screen
    local Progress = require("ui.themes.widgets.progress")
    local Layout = require("features.bars.layout")
    local Blitbuffer = require("ffi/blitbuffer")
    local face = opts.face
    local fgcolor = opts.fgcolor or Blitbuffer.COLOR_BLACK
    local cache = opts.cache
    local prefix = opts.prefix or ""
    local gap = opts.gap or Screen:scaleBySize(6)
    local icon_gap = Screen:scaleBySize(2)
    local icon_face = opts.icons and require("ui.themes.widgets.icon").face(face.orig_size)
    local color_key = tostring(fgcolor)
    local seen = {}

    --- 本条的文字控件（max_width 为 nil 即不限宽）。
    local function textWidget(entry, max_width)
        local slot = prefix .. entry.id .. (entry.flex and not max_width and "#measure" or "")
        seen[slot] = true
        return cachedTextWidget(
            slot,
            table.concat({ entry.text, tostring(face), color_key, tostring(max_width) }, "\0"),
            { text = entry.text, face = face, fgcolor = fgcolor, max_width = max_width },
            cache
        )
    end

    local prepared = {}
    for i = 1, #layout do
        local slot = layout[i]
        local meta = BY_ID[slot.id]
        if meta then
            local entry = {
                id = slot.id,
                align = slot.align == "center" and "center"
                    or slot.align == "right" and "right"
                    or "left",
                row = slot.row == "down" and "down" or "up",
                kind = meta.kind,
                text = Items.text(slot.id, ctx, opts.icons),
                flex = meta.flex == true,
                w = 0,
            }
            local glyph = icon_face and Items.glyph(slot.id, ctx)
            if glyph then
                local icon_slot = prefix .. slot.id .. "#icon"
                seen[icon_slot] = true
                entry.icon = cachedTextWidget(
                    icon_slot,
                    table.concat({ glyph, tostring(icon_face), color_key }, "\0"),
                    { text = glyph, face = icon_face, fgcolor = fgcolor, use_xtext = true },
                    cache
                )
                entry.w = entry.icon:getSize().w + (entry.text ~= "" and icon_gap or 0)
            end
            -- 非进度条一律先按真实控件宽度占位；进度条稍后吃剩余宽度，不再和标题等 flex 均分。
            if entry.kind == "bar" or entry.icon or entry.text ~= "" then
                prepared[#prepared + 1] = entry
                if entry.kind ~= "bar" and entry.text ~= "" then
                    entry.widget = textWidget(entry)
                    entry.w = entry.w + entry.widget:getSize().w
                end
            end
        end
    end

    local rows = Layout.effectiveRows(prepared, opts.stacked == true)

    local has_bar = false
    for i = 1, #prepared do
        if prepared[i].kind == "bar" then has_bar = true end
    end
    local bar_h = 0
    if has_bar then
        bar_h = opts.bar_h or Layout.progressBarHeight()
    end
    local stack_gap = (#rows > 1) and (opts.stack_gap or Screen:scaleBySize(Layout.STACK_GAP)) or 0

    --- 一行放不下时，只收缩该行里的 flex 文字（书名、章节），绝不把其它组件或进度条压到文字下面。
    local function shrinkFlex(row, band_w, row_gap)
        local other, gaps = 0, math.max(0, #row - 1) * row_gap
        local flexes = {}
        for i = 1, #row do
            local entry = row[i]
            if entry.kind ~= "bar" then
                other = other + entry.w
                if entry.flex then flexes[#flexes + 1] = entry end
            end
        end
        local overflow = other + gaps - band_w
        if overflow <= 0 or #flexes == 0 then
            return
        end
        local budget = 0
        for i = 1, #flexes do
            budget = budget + math.max(0, flexes[i].w - 1)
        end
        if budget <= 0 then return end
        for i = 1, #flexes do
            local entry = flexes[i]
            local cut = math.floor(overflow * math.max(0, entry.w - 1) / budget + 0.5)
            local new_w = math.max(1, entry.w - cut)
            local icon_w = 0
            if entry.icon then
                icon_w = entry.icon:getSize().w + (entry.text ~= "" and icon_gap or 0)
            end
            if entry.text ~= "" then
                entry.widget = textWidget(entry, math.max(1, new_w - icon_w))
            end
            entry.w = icon_w + (entry.widget and entry.widget:getSize().w or 0)
        end
    end

    --- 先给进度条分剩余宽，再按同侧原顺序放置；居中组不被条挤离可用范围。
    local function placeRow(row, band_x, band_w, row_gap)
        shrinkFlex(row, band_w, row_gap)
        local groups = { left = {}, center = {}, right = {} }
        local widths = { left = 0, center = 0, right = 0 }
        local bar
        for i = 1, #row do
            local entry = row[i]
            local group = groups[entry.align]
            widths[entry.align] = widths[entry.align] + entry.w + (#group > 0 and row_gap or 0)
            group[#group + 1] = entry
            if entry.kind == "bar" then bar = entry end
        end
        local lefts, centers, rights = groups.left, groups.center, groups.right
        local left_gap = #lefts > 0 and row_gap or 0
        local right_gap = #rights > 0 and row_gap or 0
        local function centerX()
            local min_x = widths.left + left_gap
            local max_x = band_w - widths.right - right_gap - widths.center
            return math.max(min_x, math.min(math.floor((band_w - widths.center) / 2), max_x))
        end
        if bar then
            local other = 0
            for i = 1, #row do other = other + row[i].w end
            local remain = band_w - other - math.max(0, #row - 1) * row_gap
            if #centers > 0 and bar.align ~= "center" then
                local cx = centerX()
                if bar.align == "left" then
                    remain = math.min(remain, cx - left_gap - widths.left)
                else
                    remain = math.min(remain, band_w - cx - widths.center - right_gap - widths.right)
                end
            end
            bar.w = math.max(0, math.floor(remain))
            widths[bar.align] = widths[bar.align] + bar.w
        end
        local starts = { left = 0, center = centerX(), right = band_w - widths.right }
        for align, group in pairs(groups) do
            local cursor = band_x + starts[align]
            for i = 1, #group do
                group[i].x = cursor
                cursor = cursor + group[i].w + row_gap
            end
        end
    end

    --- 在 px 处画一个条目。进度条与文字在同一行带内垂直居中；宽度为 0 的条不画。
    local function paintEntry(entry, px, band_y, band_h)
        if entry.kind == "bar" then
            if entry.w < 1 or bar_h < 1 then return end
            local bar = Progress:new{ width = entry.w, height = bar_h, percent = clampPercent(ctx.percent) }
            local by = band_y + math.max(0, math.floor((band_h - bar_h) / 2))
            bar:paintTo(bb, px, by)
            return
        end
        if entry.icon then
            paintCentered(entry.icon, bb, px, band_y, band_h)
            px = px + entry.icon:getSize().w + icon_gap
        end
        if entry.widget then
            paintCentered(entry.widget, bb, px, band_y, band_h)
        end
    end

    --- 先画进度条、再画文字，即使宽度有 1px 误差也不会把字擦掉。
    local function paintRow(row, band_y, band_h)
        for i = 1, #row do
            if row[i].kind == "bar" then
                paintEntry(row[i], row[i].x, band_y, band_h)
            end
        end
        for i = 1, #row do
            if row[i].kind ~= "bar" then
                paintEntry(row[i], row[i].x, band_y, band_h)
            end
        end
    end

    local row_hs, total_h = {}, 0
    for i = 1, #rows do
        placeRow(rows[i], x, w, gap)
        row_hs[i] = Items.rowHeight(rows[i], face, opts.icons, bar_h)
        if i > 1 then total_h = total_h + stack_gap end
        total_h = total_h + row_hs[i]
    end
    -- 单行：在整段绘制区里垂直居中（预览 56px 起步时和文字同一行）。
    -- 两行：紧凑块贴绘制区底部，空行已经丢掉，不留白。
    local origin = y
    if #rows > 1 then
        origin = y + math.max(0, h - total_h)
    end
    local cursor = origin
    for i = 1, #rows do
        local band_h = (#rows == 1) and h or row_hs[i]
        local band_y = (#rows == 1) and y or cursor
        paintRow(rows[i], band_y, band_h)
        cursor = cursor + row_hs[i] + stack_gap
    end

    if cache then
        local prefix_len = #prefix
        for slot, widget in pairs(cache.widgets) do
            local mine = prefix_len == 0 or slot:sub(1, prefix_len) == prefix
            if mine and not seen[slot] then
                if widget.free then
                    widget:free()
                end
                cache.widgets[slot] = nil
                cache.keys[slot] = nil
            end
        end
    end
end

return Items
