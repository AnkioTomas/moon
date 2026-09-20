--[[--
书籍展示共用件：字段取值、封面角标、百分比+进度条、紧凑英雄卡。
  home / detail 共用，禁止各页再抄一份 bookPct。

布局：

  封面状态（Kindle：右上互斥，左下本地下载，右下更多）
  +----------+     +----------+
  |     [NN%]|     |     已\\  |
  |          | 或  |      读\\ |
  | ✓     ···|     | ✓     ···|
  +----------+     +----------+

  hero（左封面，右栏等高）
  +------+  +---------------------------+
  |cover |  | 书名                      |
  |      |  | 作者 [/副文案]            |
  |      |  | 简介（吃满中间余量）…     |
  |      |  |                           |
  |      |  | NN%  ========····  ←贴底  |
  +------+  +---------------------------+

@module koplugin.book.ui.components.bookinfo
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextBoxWidget = require("ui/widget/textboxwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local TextWidget = require("ui/widget/textwidget")
local Widget = require("ui/widget/widget")
local GestureRange = require("ui/gesturerange")
local Image = require("ui.components.image")
local Icon = require("ui.components.icon")
local UI = require("ui.components.bookui")
local Surface = require("ui.components.surface")
local Paths = require("utils.paths")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")

---@class BookInfo
local BookInfo = {}

--- Kindle 状态叠层用近黑灰，和封面拉开对比。
---@return any
local function statusInk()
    return Blitbuffer.COLOR_GRAY_3 or Blitbuffer.COLOR_BLACK
end

--- Kindle 缎带：沿 \ 从顶边接到右边，定宽，角尖不填。
---@param bb BlitBuffer 用于绘制的 Blitbuffer 画布
---@param x number 目标区域左上角横坐标，单位像素
---@param y number 目标区域左上角纵坐标，单位像素
---@param size number 绘制区域边长，单位像素
---@param band number 斜角缎带宽度，单位像素
---@param color any Blitbuffer 使用的颜色值
---@return nil
local function paintSash(bb, x, y, size, band, color)
    for dy = 0, size - 1 do
        local x0 = dy
        local x1 = dy + band
        if x1 > size then x1 = size end
        if x1 > x0 then
            bb:paintRect(x + x0, y + dy, x1 - x0, 1, color)
        end
    end
end

--- 白像素外接盒；旋转按墨水中心，不按字体框。
---@param src table 图片来源地址或参与像素读取的源画布，具体形式由参数类型限定
---@return number, number, number, number
local function inkRect(src)
    local sw, sh = src:getWidth(), src:getHeight()
    local x0, y0, x1, y1 = sw, sh, -1, -1
    for j = 0, sh - 1 do
        for i = 0, sw - 1 do
            local pix = src:getPixel(i, j)
            local lum = pix.getColor8 and pix:getColor8().a or pix.a
            if lum and lum > 128 then
                if i < x0 then x0 = i end
                if j < y0 then y0 = j end
                if i > x1 then x1 = i end
                if j > y1 then y1 = j end
            end
        end
    end
    if x1 < x0 then
        return 0, 0, sw, sh
    end
    return x0, y0, x1 - x0 + 1, y1 - y0 + 1
end

--- 已在顶、读在右，字头朝外角。dest = 屏坐标顺时针 45°。
---@param dst table 接收绘制结果的目标画布
---@param src table 图片来源地址或参与像素读取的源画布，具体形式由参数类型限定
---@param dx number 目标画布横向偏移，单位像素
---@param dy number 目标画布纵向偏移，单位像素
---@param ox number 源内容横向起点，单位像素
---@param oy number 源内容纵向起点，单位像素
---@param sw number 源内容宽度，单位像素
---@param sh number 源内容高度，单位像素
---@return number width 旋转绘制区域的宽度
local function blitInk45(dst, src, dx, dy, ox, oy, sw, sh)
    local k = 0.70710678
    local dw = math.ceil((sw + sh) * k)
    local scx, scy = (sw - 1) / 2, (sh - 1) / 2
    local dcx = (dw - 1) / 2
    for j = 0, dw - 1 do
        for i = 0, dw - 1 do
            local fx, fy = i - dcx, j - dcx
            local sx = math.floor(fx * k + fy * k + scx + 0.5) + ox
            local sy = math.floor(-fx * k + fy * k + scy + 0.5) + oy
            if sx >= ox and sy >= oy and sx < ox + sw and sy < oy + sh then
                local pix = src:getPixel(sx, sy)
                local lum = pix.getColor8 and pix:getColor8().a or pix.a
                if lum and lum > 128 then
                    dst:setPixelClamped(dx + i, dy + j, Blitbuffer.COLOR_WHITE)
                end
            end
        end
    end
    return dw
end

--- 下载的网络封面同时落到源专属路径，供锁屏离屏渲染复用。
--- 锁屏离屏渲染不发网络请求，因此仍需要稳定的本地文件路径。
---@param book table|nil 当前操作或展示的书籍数据
---@param path string|nil 图片或书籍的本地文件路径
---@return nil
local function persistCover(book, path)
    if type(book) ~= "table" or type(path) ~= "string" or path == "" then return end
    local source_id, stable_id = book.source_id, book.stable_id
    if type(source_id) ~= "string" or source_id == ""
        or type(stable_id) ~= "string" or stable_id == "" then
        return
    end
    local target = Paths.coverPath(stable_id, source_id)
    if target == path then return end
    if lfs.attributes(target, "mode") == "file" then return end
    Paths.ensureLayout(source_id)
    local src = io.open(path, "rb")
    if not src then return end
    local data = src:read("*a")
    src:close()
    if type(data) ~= "string" or data == "" then return end
    local tmp = target .. ".part"
    local dst = io.open(tmp, "wb")
    if not dst then return end
    local ok = pcall(function() dst:write(data) end)
    dst:close()
    if not ok then
        os.remove(tmp)
        return
    end
    os.remove(target)
    os.rename(tmp, target)
end

--- 取书籍 stable_id（文件身份）。
---@param book Book|table|nil 当前操作或展示的书籍数据
---@return string|nil
function BookInfo.file(book)
    if type(book) ~= "table" then return nil end
    if type(book.stable_id) == "string" then
        return book.stable_id
    end
    return nil
end

--- 取书名；缺省回退文件 id 或「?」。
---@param book Book|table|nil 当前操作或展示的书籍数据
---@return string
function BookInfo.title(book)
    return (book and book.title) or BookInfo.file(book) or "?"
end

--- 取作者。
---@param book Book|table|nil 当前操作或展示的书籍数据
---@return string
function BookInfo.author(book)
    if type(book) ~= "table" then return "" end
    return book.authors or ""
end

--- 取简介。
---@param book Book|BookDetail|table|nil 当前操作或展示的书籍数据
---@return string
function BookInfo.desc(book)
    if type(book) ~= "table" then return "" end
    return tostring(book.intro or "")
end

--- 取阅读进度百分比（0–100）。
---@param book Book|table|nil 当前操作或展示的书籍数据
---@return number
function BookInfo.pct(book)
    if type(book) ~= "table" then return 0 end
    local p = tonumber(book.percent) or 0
    if p < 0 then p = 0 end
    if p > 100 then p = 100 end
    return p
end

--- 包一层可点击/长按容器。
---@param w number 可用宽度，单位像素
---@param h number 可用高度，单位像素
---@param on_tap fun()|nil 点击命中区域时执行的回调
---@param on_hold fun()|nil 长按命中区域时执行的回调
---@return table
function BookInfo.tappable(w, h, on_tap, on_hold)
    local tap = InputContainer:new{
        dimen = Geom:new{ w = w, h = h },
    }
    tap.ges_events = {
        TapBookInfo = {
            GestureRange:new{
                ges = "tap",
                range = function() return tap:getSize() end,
            },
        },
    }
    if on_hold then
        tap.ges_events.HoldBookInfo = {
            GestureRange:new{
                ges = "hold",
                range = function() return tap:getSize() end,
            },
        }
        tap.onHoldBookInfo = function()
            on_hold()
            return true
        end
    end
    tap.onTapBookInfo = function()
        if on_tap then on_tap() end
        return true
    end
    return tap
end

--- 已读：read_state=1。
---@param book Book|table|nil 当前操作或展示的书籍数据
---@return boolean
function BookInfo.isRead(book)
    return tonumber(book and book.read_state) == 1
end

--- 封面状态：已读与进度互斥，下载独立。
---@param book Book|table|nil 当前操作或展示的书籍数据
---@return { read: boolean, percent: boolean, downloaded: boolean }
function BookInfo.statusOverlays(book)
    local read = BookInfo.isRead(book)
    return {
        read = read,
        percent = (not read) and BookInfo.pct(book) > 0,
        downloaded = require("book.store").isDownloaded(book),
    }
end

--- 封面右上角进度角标；pct≤0 返回 nil。Kindle：小圆角胶囊、贴角留缝。
---@param cw number 封面宽度，单位像素
---@param pct number|nil 阅读进度百分比，范围 0 到 100
---@return table|nil
function BookInfo.progressBadge(cw, pct)
    if not pct or pct <= 0 then return nil end
    local badge = Surface.build{ child = TextWidget:new{
            text = string.format("%.0f%%", pct),
            face = UI.face("xx_smallinfofont", 10),
            fgcolor = Blitbuffer.COLOR_WHITE,
        }, options = {
            padding = UI.sz(4),
            padding_top = UI.sz(1),
            padding_bottom = UI.sz(1),
            width = nil,
            height = UI.sz(16),
            background = statusInk(),
            shadow = false,
        }, kind = "pill" }
    local bz = badge:getSize()
    local inset = UI.sz(4)
    badge.overlap_offset = {
        math.max(0, cw - bz.w - inset),
        inset,
    }
    return badge
end

--- 右上角「已读」斜条；文字沿 45° 走，贴齐封面角。
---@param cw number 封面宽度，单位像素
---@return table
function BookInfo.readRibbon(cw)
    local text = TextWidget:new{
        text = _("已读"),
        face = UI.face("xx_smallinfofont", 10),
        fgcolor = Blitbuffer.COLOR_WHITE,
        padding = 0,
    }
    local ts = text:getSize()
    local band = math.max(UI.sz(16), math.ceil((ts.h + UI.sz(6)) * 1.41421356))
    local size = math.max(UI.sz(40), ts.w + band)
    local ribbon = Widget:new{
        dimen = Geom:new{ w = size, h = size },
        text = text,
        band = band,
    }
    --- 返回已读缎带的固定包围盒。
    ---@return table
    function ribbon:getSize()
        return self.dimen
    end
    --- 绘制斜角已读缎带，并将文字旋转后绘制到缎带中央。
    ---@param bb BlitBuffer 用于绘制的 Blitbuffer 画布
    ---@param x number 目标区域左上角横坐标，单位像素
    ---@param y number 目标区域左上角纵坐标，单位像素
    ---@return nil
    function ribbon:paintTo(bb, x, y)
        local ink = statusInk()
        paintSash(bb, x, y, size, self.band, ink)
        if type(Blitbuffer.new) ~= "function" then
            return
        end
        local src = Blitbuffer.new(ts.w, ts.h)
        src:fill(ink)
        self.text:paintTo(src, 0, 0)
        local ix, iy, iw, ih = inkRect(src)
        local dw = math.ceil((iw + ih) * 0.70710678)
        -- 缎带平行四边形中心：中线 x=y+band/2，长度中点再收 band/4。
        local ox = x + math.floor(size / 2 + self.band / 4 - dw / 2)
        local oy = y + math.floor(size / 2 - self.band / 4 - dw / 2)
        blitInk45(bb, src, ox, oy, ix, iy, iw, ih)
        src:free()
    end
    --- 释放缎带拥有的文字控件。
    ---@return nil
    function ribbon:free()
        self.text:free()
    end
    ribbon.overlap_offset = {
        math.max(0, cw - size),
        0,
    }
    return ribbon
end

--- 封面角标：实心圆 + 白图标。ox/oy 是相对封面左上的叠层偏移。
---@param name string Material 图标名
---@param ox number 叠层横向偏移，单位像素
---@param oy number 叠层纵向偏移，单位像素
---@return table
local function circleMark(name, ox, oy)
    local size = UI.sz(18)
    local icon = Icon.widget{
        name = name,
        size = 12,
        color = Blitbuffer.COLOR_WHITE,
        box = false,
    }
    local mark = Widget:new{
        dimen = Geom:new{ w = size, h = size },
        icon = icon,
    }
    --- 返回圆形角标的固定包围盒。
    ---@return table
    function mark:getSize()
        return self.dimen
    end
    --- 绘制圆形底色和居中图标。
    ---@param bb BlitBuffer 用于绘制的 Blitbuffer 画布
    ---@param x number 目标区域左上角横坐标，单位像素
    ---@param y number 目标区域左上角纵坐标，单位像素
    ---@return nil
    function mark:paintTo(bb, x, y)
        local r = math.floor(size / 2)
        local cx, cy = x + r, y + r
        local ink = statusInk()
        if bb.paintCircle then
            bb:paintCircle(cx, cy, r, ink)
        else
            for dy = -r, r do
                local span = math.floor(math.sqrt(math.max(0, r * r - dy * dy)) + 0.5)
                if span > 0 then
                    bb:paintRect(cx - span, cy + dy, span * 2, 1, ink)
                end
            end
        end
        if self.icon then
            local iz = self.icon:getSize()
            self.icon:paintTo(
                bb,
                cx - math.floor(iz.w / 2),
                cy - math.floor(iz.h / 2)
            )
        end
    end
    --- 释放圆形角标拥有的图标控件。
    ---@return nil
    function mark:free()
        if self.icon and self.icon.free then
            self.icon:free()
        end
    end
    mark.overlap_offset = { ox, oy }
    return mark
end

--- 左下角本地下载：实心圆 + 白勾，贴边留缝。
---@param ch number 封面高度，单位像素
---@return table
function BookInfo.downloadMark(ch)
    local size, inset = UI.sz(18), UI.sz(4)
    return circleMark("check", inset, math.max(0, ch - size - inset))
end

--- 右下角「更多」：实心圆 + more_horiz，贴边留缝。
---@param cw number 封面宽度，单位像素
---@param ch number 封面高度，单位像素
---@return table
function BookInfo.moreMark(cw, ch)
    local size, inset = UI.sz(18), UI.sz(4)
    return circleMark(
        "more_horiz",
        math.max(0, cw - size - inset),
        math.max(0, ch - size - inset)
    )
end

--- 封面正中「正在打开」黑条。
---@param cw number 封面宽度，单位像素
---@param ch number 封面高度，单位像素
---@return table
function BookInfo.openingBar(cw, ch)
    local bar_h = UI.sz(22)
    local text = TextWidget:new{
        text = _("正在打开"),
        face = UI.face("xx_smallinfofont", 11),
        fgcolor = Blitbuffer.COLOR_WHITE,
    }
    local bar = Widget:new{
        dimen = Geom:new{ w = cw, h = bar_h },
        text = text,
    }
    --- 返回打开中条带的固定包围盒。
    ---@return table
    function bar:getSize()
        return self.dimen
    end
    --- 绘制通栏黑底和居中文案。
    ---@param bb BlitBuffer 用于绘制的 Blitbuffer 画布
    ---@param x number 目标区域左上角横坐标，单位像素
    ---@param y number 目标区域左上角纵坐标，单位像素
    ---@return nil
    function bar:paintTo(bb, x, y)
        bb:paintRect(x, y, cw, bar_h, Blitbuffer.COLOR_BLACK)
        if not self.text then return end
        local tz = self.text:getSize()
        self.text:paintTo(
            bb,
            x + math.floor((cw - tz.w) / 2),
            y + math.floor((bar_h - tz.h) / 2)
        )
    end
    --- 释放条带拥有的文字控件。
    ---@return nil
    function bar:free()
        if self.text and self.text.free then
            self.text:free()
        end
    end
    bar.overlap_offset = {
        0,
        math.max(0, math.floor((ch - bar_h) / 2)),
    }
    return bar
end

--- 「NN%」+ 进度条；百分比在左。
---@param width number 目标宽度，单位像素
---@param pct number|nil 阅读进度百分比，范围 0 到 100
---@return table, number
function BookInfo.progressRow(width, pct)
    pct = tonumber(pct) or 0
    local label = TextWidget:new{
        text = string.format("%.0f%%", pct),
        face = UI.face("xx_smallinfofont", 12),
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local label_w = label:getSize().w
    local gap = UI.sz(6)
    local bar_h = UI.sz(7)
    local bar_w = math.max(1, width - label_w - gap)
    local row = HorizontalGroup:new{
        align = "center",
        label,
        HorizontalSpan:new{ width = gap },
        UI.progressBar(bar_w, bar_h, pct),
    }
    return row, math.max(label:getSize().h, bar_h)
end

--- 封面 widget。
--- opts.badge: 未读且有进度时叠右上角百分比
--- opts.ribbon: 已读时叠右上角「已读」绑带
--- opts.download: 已本地下载时叠左下角勾（章节源看全本缓存，整本源看 path）
--- opts.more: 叠右下角「更多」；true 只画，function 同时可点
--- opts.show_parent: 窗口级父（Desktop / Detail）
--- opts.on_ready: 图片就绪回调
--- opts.src / opts.headers: 直接指定封面（刮削结果没有 source.coverRequest）
--- 有 book.source_id 时按属主源 coverRequest，禁止用活跃源冒充。
---@param plugin table|nil 插件实例，用于打开书籍和调用插件功能
---@param source table|nil 书无 source_id 时的数据源（书城未入库项）
---@param book table|nil 当前操作或展示的书籍数据
---@param cw number 封面宽度，单位像素
---@param ch number 封面高度，单位像素
---@param opts table|nil 布局尺寸、样式及行为选项；缺省项使用组件默认值
---@return table, number, number
function BookInfo.cover(plugin, source, book, cw, ch, opts)
    opts = opts or {}
    local title = BookInfo.title(book)
    local pct = BookInfo.pct(book)
    local req
    if type(opts.src) == "string" and opts.src ~= "" then
        req = { url = opts.src, headers = opts.headers }
    elseif type(book) == "table" and type(book.cover_url) == "string" and book.cover_url ~= "" then
        req = { url = book.cover_url, headers = book.cover_headers }
    elseif type(book) == "table" and type(book.cover) == "string" and book.cover ~= "" then
        req = { url = book.cover, headers = book.cover_headers }
    end
    if not req and type(book) == "table" and type(book.stable_id) == "string" then
        local sid = book.source_id
        if type(sid) == "string" and sid ~= "" then
            local cached = Paths.coverPath(book.stable_id, sid)
            if lfs.attributes(cached, "mode") == "file" then
                req = { url = cached }
            end
        end
        if not req then
            local owner = source
            if type(sid) == "string" and sid ~= "" and (not source or source.id ~= sid) then
                owner = require("source.registry").resolve(sid)
            end
            if owner and type(owner.coverRequest) == "function" then
                req = select(1, owner:coverRequest(book))
            end
        end
    end
    local cover_pad = UI.sz(2)
    local cover_w = math.max(UI.sz(16), cw - cover_pad * 2)
    local cover_h = math.max(UI.sz(24), ch - cover_pad * 2)
    local on_ready = opts.on_ready
    local image = Image.widget{
        src = req and req.url or nil,
        headers = req and req.headers or nil,
        width = cover_w,
        height = cover_h,
        alpha = false,
        border = false,
        fallback = title,
        show_parent = opts.show_parent,
        on_ready = function(path)
            persistCover(book, path)
            if on_ready then on_ready(path) end
        end,
    }
    local cover = Surface.build{ child = image, options = {
        padding = cover_pad,
        radius = UI.cardRadius(),
        background = UI.surface(),
        clip = true,
        clip_background = UI.surface(),
        shadow = opts.shadow,
    }, kind = "card" }
    local status = BookInfo.statusOverlays(book)
    local show_read = opts.ribbon and status.read
    local show_pct = opts.badge and status.percent
    local show_dl = opts.download and status.downloaded
    local show_more = opts.more
    if show_read or show_pct or show_dl or show_more then
        local overlays = {
            dimen = Geom:new{ w = cw, h = ch },
            show_parent = opts.show_parent,
            cover,
        }
        if show_read then
            overlays[#overlays + 1] = BookInfo.readRibbon(cw)
        elseif show_pct then
            overlays[#overlays + 1] = BookInfo.progressBadge(cw, pct)
        end
        if show_dl then
            overlays[#overlays + 1] = BookInfo.downloadMark(ch)
        end
        if show_more then
            local mark = BookInfo.moreMark(cw, ch)
            if type(opts.more) == "function" then
                local mz = mark:getSize()
                local tap = BookInfo.tappable(mz.w, mz.h, opts.more)
                tap[1] = mark
                tap.overlap_offset = mark.overlap_offset
                mark = tap
            end
            overlays[#overlays + 1] = mark
        end
        cover = OverlapGroup:new(overlays)
    end
    return cover, cw, ch
end

--- 英雄卡：左封面，右栏高度对齐封面。
--- 上：书名/作者[/副文案]/简介（简介吃满中间余量，不写死行数）
--- 下：进度条贴底（opts.show_progress=false 时隐藏，刮削结果用）
--- opts: width, pad, on_tap, show_progress, show_desc, subtitle, src, headers；返回 widget, height
--- show_desc=false：Z站详情只在下方「简介」区展示全文，避免英雄卡再摘要一遍。
---@param plugin table|nil 插件实例，用于打开书籍和调用插件功能
---@param source table|nil 书籍所属数据源实例
---@param book table|nil 当前操作或展示的书籍数据
---@param opts table|nil 布局尺寸、样式及行为选项；缺省项使用组件默认值
---@return table, number
function BookInfo.hero(plugin, source, book, opts)
    opts = opts or {}
    local w = opts.width or 1
    local pad = opts.pad or UI.sz(10)
    local avail = math.max(1, w - pad * 2)
    local gap = UI.sz(8)
    local cw = math.min(UI.sz(80), math.floor(avail * 0.22))
    if opts.cover_width then
        cw = math.max(1, math.min(
            math.floor(opts.cover_width),
            avail - gap - UI.sz(40)
        ))
    end
    local ch = math.floor(cw * 3 / 2)
    local show_progress = opts.show_progress ~= false
    local show_desc = opts.show_desc ~= false

    local cover = select(1, BookInfo.cover(plugin, source, book, cw, ch, {
        badge = false,
        show_parent = opts.show_parent,
        on_ready = opts.on_ready,
        src = opts.src,
        headers = opts.headers,
    }))
    local cover_box = cover
    if opts.on_tap then
        cover_box = BookInfo.tappable(cw, ch, opts.on_tap)
        cover_box[1] = cover
    end

    local info_w = math.max(UI.sz(40), avail - cw - gap)
    local title = BookInfo.title(book)
    local author = BookInfo.author(book)
    local desc = show_desc and BookInfo.desc(book) or ""
    local pct = BookInfo.pct(book)
    local subtitle = opts.subtitle

    local progress_h = 0
    local progress
    if show_progress then
        progress, progress_h = BookInfo.progressRow(info_w, pct)
    end
    local gap_head = UI.sz(2)
    local gap_desc = UI.sz(3)
    local gap_foot = show_progress and UI.sz(4) or 0

    local title_w = TextWidget:new{
        text = title,
        face = UI.face("cfont", 16),
        max_width = info_w,
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local author_w = TextWidget:new{
        text = author ~= "" and author or _("未知作者"),
        face = UI.face("xx_smallinfofont", 12),
        max_width = info_w,
        fgcolor = UI.muted(),
    }

    local head_h = title_w:getSize().h + gap_head + author_w:getSize().h
    local top_kids = {
        align = "left",
        title_w,
        VerticalSpan:new{ width = gap_head },
        author_w,
    }
    if type(subtitle) == "string" and subtitle ~= "" then
        local sub_w = TextWidget:new{
            text = subtitle,
            face = UI.face("xx_smallinfofont", 11),
            max_width = info_w,
            fgcolor = UI.dim(),
        }
        table.insert(top_kids, VerticalSpan:new{ width = gap_head })
        table.insert(top_kids, sub_w)
        head_h = head_h + gap_head + sub_w:getSize().h
    end

    local mid_budget = math.max(0, ch - head_h - gap_foot - progress_h)
    if desc ~= "" and mid_budget > gap_desc then
        table.insert(top_kids, VerticalSpan:new{ width = gap_desc })
        table.insert(top_kids, TextBoxWidget:new{
            text = desc,
            face = UI.face("xx_smallinfofont", 11),
            width = info_w,
            height = mid_budget - gap_desc,
            alignment = "left",
            fgcolor = UI.muted(),
            height_overflow_show_ellipsis = true,
        })
        head_h = head_h + mid_budget
    end

    local filler = math.max(0, ch - head_h - gap_foot - progress_h)
    local info_kids = {
        align = "left",
        VerticalGroup:new(top_kids),
        VerticalSpan:new{ width = filler },
    }
    if show_progress then
        table.insert(info_kids, VerticalSpan:new{ width = gap_foot })
        table.insert(info_kids, progress)
    end
    local info = VerticalGroup:new(info_kids)

    if opts.on_tap then
        local tap = BookInfo.tappable(info_w, ch, opts.on_tap)
        tap[1] = info
        info = tap
    end

    local pad_v = UI.sz(6)
    local widget = Surface.build{ child = HorizontalGroup:new{
            align = "top",
            cover_box,
            HorizontalSpan:new{ width = gap },
            LeftContainer:new{
                dimen = Geom:new{ w = info_w, h = ch },
                info,
            },
        }, options = {
        padding = pad,
        padding_top = pad_v,
        padding_bottom = pad_v,
        background = false,
        radius = 0,
        shadow = false,
    }, kind = "card" }
    return widget, widget:getSize().h
end

return BookInfo
