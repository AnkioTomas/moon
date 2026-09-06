--[[--
书籍展示共用件：字段取值、封面角标、百分比+进度条、紧凑英雄卡。
  home / detail 共用，禁止各页再抄一份 bookPct。

布局：

  封面状态（Kindle：右上互斥，左下本地下载）
  +----------+     +----------+
  |     [NN%]|     |     已\\  |
  |          | 或  |      读\\ |
  | ✓        |     | ✓        |
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

local BookInfo = {}

--- Kindle 状态叠层用近黑灰，和封面拉开对比。
---@return any
local function statusInk()
    return Blitbuffer.COLOR_GRAY_3 or Blitbuffer.COLOR_BLACK
end

--- Kindle 缎带：沿 \ 从顶边接到右边，定宽，角尖不填。
---@param bb table
---@param x number
---@param y number
---@param size number
---@param band number
---@param color any
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
---@param src table
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
---@param dst table
---@param src table
---@param dx number
---@param dy number
---@param ox number
---@param oy number
---@param sw number
---@param sh number
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
---@param book table|nil
---@param path string|nil
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
---@param book Book|table|nil
---@return string|nil
function BookInfo.file(book)
    if type(book) ~= "table" then return nil end
    if type(book.stable_id) == "string" then
        return book.stable_id
    end
    return nil
end

--- 取书名；缺省回退文件 id 或「?」。
---@param book Book|table|nil
---@return string
function BookInfo.title(book)
    return (book and book.title) or BookInfo.file(book) or "?"
end

--- 取作者。
---@param book Book|table|nil
---@return string
function BookInfo.author(book)
    if type(book) ~= "table" then return "" end
    return book.authors or ""
end

--- 取简介。
---@param book Book|BookDetail|table|nil
---@return string
function BookInfo.desc(book)
    if type(book) ~= "table" then return "" end
    return tostring(book.intro or "")
end

--- 取阅读进度百分比（0–100）。
---@param book Book|table|nil
---@return number
function BookInfo.pct(book)
    if type(book) ~= "table" then return 0 end
    local p = tonumber(book.percent) or 0
    if p < 0 then p = 0 end
    if p > 100 then p = 100 end
    return p
end

--- 包一层可点击/长按容器。
---@param w number
---@param h number
---@param on_tap fun()|nil
---@param on_hold fun()|nil
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
---@param book Book|table|nil
---@return boolean
function BookInfo.isRead(book)
    return tonumber(book and book.read_state) == 1
end

--- 封面状态：已读与进度互斥，下载独立。
---@param book Book|table|nil
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
---@param cw number
---@param pct number|nil
---@return table|nil
function BookInfo.progressBadge(cw, pct)
    if not pct or pct <= 0 then return nil end
    local badge = Surface.pill(TextWidget:new{
            text = string.format("%.0f%%", pct),
            face = UI.face("xx_smallinfofont", 10),
            fgcolor = Blitbuffer.COLOR_WHITE,
        }, {
            padding = UI.sz(4),
            padding_top = UI.sz(1),
            padding_bottom = UI.sz(1),
            width = nil,
            height = UI.sz(16),
            background = statusInk(),
            shadow = false,
        })
    local bz = badge:getSize()
    local inset = UI.sz(4)
    badge.overlap_offset = {
        math.max(0, cw - bz.w - inset),
        inset,
    }
    return badge
end

--- 右上角「已读」斜条；文字沿 45° 走，贴齐封面角。
---@param cw number
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
    function ribbon:getSize()
        return self.dimen
    end
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
    function ribbon:free()
        self.text:free()
    end
    ribbon.overlap_offset = {
        math.max(0, cw - size),
        0,
    }
    return ribbon
end

--- 左下角本地下载：实心圆 + 白勾，贴边留缝。
---@param ch number
---@return table
function BookInfo.downloadMark(ch)
    local size = UI.sz(18)
    local icon = Icon.widget{
        name = "check",
        size = 12,
        color = Blitbuffer.COLOR_WHITE,
        box = false,
    }
    local mark = Widget:new{
        dimen = Geom:new{ w = size, h = size },
        icon = icon,
    }
    function mark:getSize()
        return self.dimen
    end
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
    function mark:free()
        if self.icon and self.icon.free then
            self.icon:free()
        end
    end
    local inset = UI.sz(4)
    mark.overlap_offset = {
        inset,
        math.max(0, ch - size - inset),
    }
    return mark
end

--- 「NN%」+ 进度条；百分比在左。
---@param width number
---@param pct number|nil
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
--- opts.show_parent: 窗口级父（Desktop / Detail）
--- opts.on_ready: 图片就绪回调
--- opts.src / opts.headers: 直接指定封面（刮削结果没有 source.coverRequest）
---@param plugin table|nil
---@param source table|nil
---@param book table|nil
---@param cw number
---@param ch number
---@param opts table|nil
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
    elseif source and type(source.coverRequest) == "function"
        and type(book) == "table" and type(book.stable_id) == "string" then
        req = select(1, source:coverRequest(book))
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
        sync = opts.sync,
    }
    local cover = Surface.card(image, {
        padding = cover_pad,
        radius = UI.cardRadius(),
        background = UI.surface(),
        clip = true,
        clip_background = UI.surface(),
        shadow = opts.shadow,
    })
    local status = BookInfo.statusOverlays(book)
    local show_read = opts.ribbon and status.read
    local show_pct = opts.badge and status.percent
    local show_dl = opts.download and status.downloaded
    if show_read or show_pct or show_dl then
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
        cover = OverlapGroup:new(overlays)
    end
    return cover, cw, ch
end

--- 英雄卡：左封面，右栏高度对齐封面。
--- 上：书名/作者[/副文案]/简介（简介吃满中间余量，不写死行数）
--- 下：进度条贴底（opts.show_progress=false 时隐藏，刮削结果用）
--- opts: width, pad, on_tap, show_progress, subtitle, src, headers；返回 widget, height
---@param plugin table|nil
---@param source table|nil
---@param book table|nil
---@param opts table|nil
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

    local cover = select(1, BookInfo.cover(plugin, source, book, cw, ch, {
        badge = false,
        show_parent = opts.show_parent,
        on_ready = opts.on_ready,
        src = opts.src,
        headers = opts.headers,
        sync = opts.sync,
    }))
    local cover_box = cover
    if opts.on_tap then
        cover_box = BookInfo.tappable(cw, ch, opts.on_tap)
        cover_box[1] = cover
    end

    local info_w = math.max(UI.sz(40), avail - cw - gap)
    local title = BookInfo.title(book)
    local author = BookInfo.author(book)
    local desc = BookInfo.desc(book)
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
    local widget = Surface.card(HorizontalGroup:new{
            align = "top",
            cover_box,
            HorizontalSpan:new{ width = gap },
            LeftContainer:new{
                dimen = Geom:new{ w = info_w, h = ch },
                info,
            },
        }, {
        padding = pad,
        padding_top = pad_v,
        padding_bottom = pad_v,
        background = false,
        radius = 0,
        shadow = false,
    })
    return widget, widget:getSize().h
end

return BookInfo
