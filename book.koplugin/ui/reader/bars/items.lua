--[[--
阅读页栏组件目录与绘制。

只认 ctx 里的字符串和数字，不碰桌面顶栏的 View / Lifecycle。
paint 是 ReaderView 热路径：文本控件可缓存。

@module koplugin.book.ui.reader.bars.items
--]]

require("l10n").apply()
local _ = require("gettext")

local Items = {}

---@class BookReaderBarItem
---@field id string
---@field label string
---@field icon string
---@field top boolean|nil
---@field bottom boolean|nil
---@field flex boolean|nil
---@field kind string|nil "bar" 时画进度条

Items.CATALOG = {
    { id = "chapter", label = _("章节"), icon = "menu_book", top = true, bottom = true, flex = true },
    { id = "title", label = _("书名"), icon = "book", top = true, bottom = true, flex = true },
    { id = "clock", label = _("时钟"), icon = "schedule", top = true, bottom = true },
    { id = "battery", label = _("电池"), icon = "battery_android_full", top = true, bottom = true },
    { id = "wifi", label = _("Wi-Fi"), icon = "wifi", top = true, bottom = true },
    { id = "brightness", label = _("亮度"), icon = "brightness_6", top = true, bottom = true },
    { id = "page", label = _("页码"), icon = "pin", top = true, bottom = true },
    { id = "percent", label = _("进度"), icon = "percent", top = true, bottom = true },
    { id = "chapter_idx", label = _("章节序号"), icon = "format_list_numbered", top = true, bottom = true },
    { id = "remaining", label = _("剩余时间"), icon = "schedule", top = true, bottom = true },
    { id = "progress_bar", label = _("进度条"), icon = "horizontal_rule", bottom = true, flex = true, kind = "bar" },
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

--- 按 id 取目录项。
---@param id string
---@return BookReaderBarItem|nil
function Items.meta(id)
    return BY_ID[id]
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
        remaining_seconds = 1800,
        remaining = _("约 30 分钟"),
        battery = "85%",
        wifi = _("Wi-Fi"),
        brightness = "40%",
    }
end

---@param pct number
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

---@return string
local function liveBattery()
    local ok, Device = pcall(require, "device")
    if not ok or not Device or not Device.hasBattery or not Device:hasBattery() or not Device.powerd then
        return ""
    end
    local pct = Device.powerd:getCapacity()
    if type(pct) ~= "number" then
        return ""
    end
    return string.format("%d%%", math.floor(clampPercent(pct) + 0.5))
end

---@return string
local function liveWifi()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok or not NetworkMgr or not NetworkMgr.isWifiOn then
        return ""
    end
    return NetworkMgr:isWifiOn() and _("Wi-Fi") or _("离线")
end

---@return string
local function liveBrightness()
    local ok, Device = pcall(require, "device")
    if not ok or not Device or not Device.hasFrontlight or not Device:hasFrontlight() then
        return ""
    end
    local powerd = Device.powerd
    if not powerd or not powerd.frontlightIntensity then
        return ""
    end
    local lvl = powerd:frontlightIntensity()
    if type(lvl) ~= "number" then
        return ""
    end
    return string.format("%d%%", math.floor(clampPercent(lvl) + 0.5))
end

--- 组件文案；进度条返回空串。
---@param id string
---@param ctx table
---@return string
function Items.text(id, ctx)
    ctx = ctx or {}
    if id == "chapter" then
        return ctx.chapter or ""
    end
    if id == "title" then
        return ctx.title or ""
    end
    if id == "clock" then
        return ctx.clock or ""
    end
    if id == "battery" then
        return ctx.battery or liveBattery()
    end
    if id == "wifi" then
        return ctx.wifi or liveWifi()
    end
    if id == "brightness" then
        return ctx.brightness or liveBrightness()
    end
    if id == "page" then
        local page = tonumber(ctx.page)
        local total = tonumber(ctx.total_pages)
        if page and total and total > 0 then
            return string.format("%d/%d", page, total)
        end
        return ""
    end
    if id == "percent" then
        return string.format("%.0f%%", clampPercent(ctx.percent))
    end
    if id == "chapter_idx" then
        local idx = tonumber(ctx.chapter_idx)
        local count = tonumber(ctx.chapter_count)
        if idx and count and count > 0 then
            return string.format(_("第 %d/%d 章"), idx, count)
        end
        return ""
    end
    if id == "remaining" then
        return ctx.remaining or ""
    end
    return ""
end

---@param slot string
---@param key string
---@param opts table
---@param cache table|nil
---@return table
local function cachedTextWidget(slot, key, opts, cache)
    if not cache then
        local TextWidget = require("ui/widget/textwidget")
        return TextWidget:new(opts)
    end
    local old_key = cache.keys[slot]
    local widget = cache.widgets[slot]
    if not widget or old_key ~= key then
        if widget and widget.free then
            widget:free()
        end
        local TextWidget = require("ui/widget/textwidget")
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
---@param opts table
function Items.paint(bb, x, y, w, h, layout, ctx, opts)
    opts = opts or {}
    local Device = require("device")
    local Screen = Device.screen
    local UI = require("ui.components.bookui")
    local Blitbuffer = require("ffi/blitbuffer")
    local face = opts.face
    local fgcolor = opts.fgcolor or Blitbuffer.COLOR_BLACK
    local cache = opts.cache
    local prefix = opts.prefix or ""
    local gap = opts.gap or Screen:scaleBySize(6)
    local seen = {}

    local prepared = {}
    local intrinsic = 0
    local flex_n = 0
    local painted_n = 0
    for i = 1, #(layout or {}) do
        local slot = layout[i]
        local meta = BY_ID[slot.id]
        if meta then
            local kind = meta.kind
            local text = kind == "bar" and "" or Items.text(slot.id, ctx)
            if kind == "bar" or text ~= "" then
                local entry = {
                    id = slot.id,
                    align = slot.align == "right" and "right" or "left",
                    kind = kind,
                    text = text,
                    flex = meta.flex == true,
                }
                prepared[#prepared + 1] = entry
                painted_n = painted_n + 1
                if entry.flex then
                    flex_n = flex_n + 1
                else
                    local widget = cachedTextWidget(
                        prefix .. slot.id,
                        table.concat({ text, tostring(face), tostring(fgcolor) }, "\0"),
                        { text = text, face = face, fgcolor = fgcolor },
                        cache
                    )
                    entry.widget = widget
                    entry.w = widget:getSize().w
                    intrinsic = intrinsic + entry.w
                    if cache then
                        seen[prefix .. slot.id] = true
                    end
                end
            end
        end
    end

    if painted_n == 0 then
        return
    end
    local gaps = math.max(0, painted_n - 1) * gap
    local remain = math.max(0, w - intrinsic - gaps)
    local flex_w = flex_n > 0 and math.max(1, math.floor(remain / flex_n)) or 0

    for i = 1, #prepared do
        local entry = prepared[i]
        if entry.flex then
            entry.w = flex_w
            if entry.kind ~= "bar" then
                local widget = cachedTextWidget(
                    prefix .. entry.id,
                    table.concat({ entry.text, tostring(face), tostring(fgcolor), tostring(flex_w) }, "\0"),
                    { text = entry.text, face = face, fgcolor = fgcolor, max_width = flex_w },
                    cache
                )
                entry.widget = widget
                if cache then
                    seen[prefix .. entry.id] = true
                end
            end
        end
    end

    local cursor = { left = x, right = x + w }
    for i = 1, #prepared do
        local entry = prepared[i]
        if entry.align == "left" then
            if entry.kind == "bar" then
                local bar_h = opts.bar_h or UI.sz(6)
                local bar = UI.progressBar(entry.w, bar_h, clampPercent(ctx.percent))
                bar:paintTo(bb, cursor.left, y + math.floor((h - bar_h) / 2))
                bar:free()
            else
                paintCentered(entry.widget, bb, cursor.left, y, h)
            end
            cursor.left = cursor.left + entry.w + gap
        end
    end
    for i = #prepared, 1, -1 do
        local entry = prepared[i]
        if entry.align == "right" then
            cursor.right = cursor.right - entry.w
            if entry.kind == "bar" then
                local bar_h = opts.bar_h or UI.sz(6)
                local bar = UI.progressBar(entry.w, bar_h, clampPercent(ctx.percent))
                bar:paintTo(bb, cursor.right, y + math.floor((h - bar_h) / 2))
                bar:free()
            else
                paintCentered(entry.widget, bb, cursor.right, y, h)
            end
            cursor.right = cursor.right - gap
        end
    end

    if cache then
        local prefix_len = #prefix
        for slot, widget in pairs(cache.widgets) do
            local mine = prefix_len == 0 or slot:sub(1, prefix_len) == prefix
            if mine and not seen[slot] then
                if widget and widget.free then
                    widget:free()
                end
                cache.widgets[slot] = nil
                cache.keys[slot] = nil
            end
        end
    end
end

return Items
