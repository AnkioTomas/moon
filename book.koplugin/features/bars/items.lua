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
        text = function(ctx) return fraction(ctx.page, ctx.total_pages, "%d/%d") end,
    },
    {
        id = "percent", label = _("进度"), icon = "percent", top = true, bottom = true,
        text = function(ctx) return string.format("%.0f%%", clampPercent(ctx.percent)) end,
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
        text = function(ctx, icons)
            return fraction(ctx.chapter_page, ctx.chapter_pages, _("本章 %d/%d"), icons)
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
---@param opts { face: table, fgcolor: table|nil, cache: table|nil, prefix: string|nil, gap: number|nil, bar_h: number|nil, icons: boolean|nil }
function Items.paint(bb, x, y, w, h, layout, ctx, opts)
    local Device = require("device")
    local Screen = Device.screen
    local Progress = require("ui.themes.widgets.progress")
    local Theme = require("ui.themes")
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
        local slot = prefix .. entry.id
        seen[slot] = true
        return cachedTextWidget(
            slot,
            table.concat({ entry.text, tostring(face), color_key, tostring(max_width) }, "\0"),
            { text = entry.text, face = face, fgcolor = fgcolor, max_width = max_width },
            cache
        )
    end

    local prepared = {}
    local intrinsic = 0
    local flex_n = 0
    for i = 1, #layout do
        local slot = layout[i]
        local meta = BY_ID[slot.id]
        if meta then
            local entry = {
                id = slot.id,
                align = slot.align == "right" and "right" or "left",
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
            if entry.kind == "bar" or entry.icon or entry.text ~= "" then
                prepared[#prepared + 1] = entry
                if entry.flex then
                    flex_n = flex_n + 1
                elseif entry.text ~= "" then
                    entry.widget = textWidget(entry)
                    entry.w = entry.w + entry.widget:getSize().w
                end
                if not entry.flex then
                    intrinsic = intrinsic + entry.w
                end
            end
        end
    end

    local gaps = math.max(0, #prepared - 1) * gap
    local remain = math.max(0, w - intrinsic - gaps)
    local flex_w = flex_n > 0 and math.max(1, math.floor(remain / flex_n)) or 0

    for i = 1, #prepared do
        local entry = prepared[i]
        if entry.flex then
            if entry.kind ~= "bar" and entry.text ~= "" then
                entry.widget = textWidget(entry, math.max(1, flex_w - entry.w))
            end
            entry.w = flex_w
        end
    end

    --- 在 px 处画一个条目：进度条临时建（自绘无资源，不用释放）；图标在前，文字随后。
    local function paintEntry(entry, px)
        if entry.kind == "bar" then
            local bar_h = opts.bar_h or Theme.px(Theme.current().progress.height)
            local bar = Progress:new{ width = entry.w, height = bar_h, percent = clampPercent(ctx.percent) }
            bar:paintTo(bb, px, y + math.floor((h - bar_h) / 2))
            return
        end
        if entry.icon then
            paintCentered(entry.icon, bb, px, y, h)
            px = px + entry.icon:getSize().w + icon_gap
        end
        if entry.widget then
            paintCentered(entry.widget, bb, px, y, h)
        end
    end
    local left, right = x, x + w
    for i = 1, #prepared do
        local entry = prepared[i]
        if entry.align == "left" then
            paintEntry(entry, left)
            left = left + entry.w + gap
        end
    end
    for i = #prepared, 1, -1 do
        local entry = prepared[i]
        if entry.align == "right" then
            right = right - entry.w
            paintEntry(entry, right)
            right = right - gap
        end
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
