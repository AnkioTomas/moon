--[[--
一本书的展示：字段取值、封面（角标）和封面下的书名。作者行由 show_author 决定，缺省不显示。

  +----------+
  |     [NN%]|
  |          |
  | ✓     ···|
  +----------+
  书名
  作者          ← 仅 show_author

@module koplugin.book.ui.widgets.book
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local CenterContainer = require("ui/widget/container/centercontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local LeftContainer = require("ui/widget/container/leftcontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local GestureRange = require("ui/gesturerange")
local Image = require("ui.themes.widgets.image")
local Icon = require("ui.themes.widgets.icon")
local Box = require("ui.themes.widgets.box")
local PlainCover = require("ui.widgets.plain_cover")
local Text = require("ui.themes.widgets.text")
local Theme = require("ui.themes")
local Paths = require("utils.paths")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")

---@class BookWidget
local Book = {}

--- Kindle 状态叠层用近黑灰，和封面拉开对比。
local function statusInk()
    return Blitbuffer.Color8(Theme.current().color.ink)
end

--- Kindle 缎带：沿 \ 从顶边接到右边，定宽，角尖不填。
---@param bb BlitBuffer 用于绘制的 Blitbuffer 画布
---@param x number 目标区域左上角横坐标，单位像素
---@param y number 目标区域左上角纵坐标，单位像素
---@param size number 绘制区域边长，单位像素
---@param band number 斜角缎带宽度，单位像素
---@param color any Blitbuffer 使用的颜色值
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

--- 源画布该像素是否为白字墨水。
---@param src table 参与像素读取的源画布
---@param x number 像素横坐标
---@param y number 像素纵坐标
---@return boolean
local function inked(src, x, y)
    return src:getPixel(x, y):getColor8().a > 128
end

--- 白像素外接盒；旋转按墨水中心，不按字体框。
---@param src table 图片来源地址或参与像素读取的源画布，具体形式由参数类型限定
---@return number, number, number, number
local function inkRect(src)
    local sw, sh = src:getWidth(), src:getHeight()
    local x0, y0, x1, y1 = sw, sh, -1, -1
    for j = 0, sh - 1 do
        for i = 0, sw - 1 do
            if inked(src, i, j) then
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
            if sx >= ox and sy >= oy and sx < ox + sw and sy < oy + sh and inked(src, sx, sy) then
                dst:setPixelClamped(dx + i, dy + j, Blitbuffer.COLOR_WHITE)
            end
        end
    end
    return dw
end

--- 下载的网络封面同时落到源专属路径，供锁屏离屏渲染复用。
--- 锁屏离屏渲染不发网络请求，因此仍需要稳定的本地文件路径。
---@param book table|nil 当前操作或展示的书籍数据
---@param path string|nil 图片或书籍的本地文件路径
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
    local tmp = target .. ".part"
    local dst = io.open(tmp, "wb")
    if not dst then
        src:close()
        return
    end
    -- 分块拷贝，不把整张封面读进内存；空文件也算失败
    local ok, size = pcall(function()
        local n = 0
        for chunk in function() return src:read(64 * 1024) end do
            assert(dst:write(chunk))
            n = n + #chunk
        end
        return n
    end)
    src:close()
    dst:close()
    if not ok or size == 0 then
        os.remove(tmp)
        return
    end
    os.remove(target)
    os.rename(tmp, target)
end

--- 远程封面落盘到本地封面缓存（锁屏海报预取复用）。
Book.persistCover = persistCover

--- 取书名；缺省回退文件 id 或「?」。
---@param book Book|table|nil 当前操作或展示的书籍数据
---@return string
function Book.title(book)
    return book and (book.title or book.stable_id) or "?"
end

--- 取作者。
---@param book Book|table|nil 当前操作或展示的书籍数据
---@return string
function Book.author(book)
    if type(book) ~= "table" then return "" end
    return book.authors or ""
end

--- 取简介。
---@param book Book|BookDetail|table|nil 当前操作或展示的书籍数据
---@return string
function Book.desc(book)
    if type(book) ~= "table" then return "" end
    return tostring(book.intro or "")
end

--- 取阅读进度百分比（0–100）。
---@param book Book|table|nil 当前操作或展示的书籍数据
---@return number
function Book.pct(book)
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
function Book.tappable(w, h, on_tap, on_hold)
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
function Book.isRead(book)
    return tonumber(book and book.read_state) == 1
end

--- 封面右上角进度角标；pct≤0 返回 nil。Kindle：小圆角胶囊、贴角留缝。
---@param cw number 封面宽度，单位像素
---@param pct number|nil 阅读进度百分比，范围 0 到 100
---@return table|nil
function Book.progressBadge(cw, pct)
    if not pct or pct <= 0 then return nil end
    local t = Theme.current()
    local badge = Box:new{
        style = {
            bg = t.color.ink, radius = 999, border = 0, shadow = 0,
            border_color = 0, shadow_color = 0,
        },
        height = Theme.px(16),
        padding = Theme.px(t.space.xs),
        Text.line("caption", string.format("%.0f%%", pct), { color = t.color.page }),
    }
    local bz = badge:getSize()
    local inset = Theme.px(t.space.xs)
    badge.overlap_offset = {
        math.max(0, cw - bz.w - inset),
        inset,
    }
    return badge
end

--- 右上角「已读」斜条；文字沿 45° 走，贴齐封面角。
---@param cw number 封面宽度，单位像素
---@return table
function Book.readRibbon(cw)
    local text = Text.line("caption", _("已读"), { color = Theme.current().color.page })
    local ts = text:getSize()
    local band = math.max(Theme.px(16), math.ceil((ts.h + Theme.px(6)) * 1.41421356))
    local size = math.max(Theme.px(40), ts.w + band)
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
    function ribbon:paintTo(bb, x, y)
        local ink = statusInk()
        paintSash(bb, x, y, size, self.band, ink)
        ---@type BlitBuffer
        ---@diagnostic disable-next-line: assign-type-mismatch
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
    local t = Theme.current()
    local size = Theme.px(18)
    local icon = Icon.widget{
        name = name,
        size = t.font.caption,
        color = Blitbuffer.Color8(t.color.page),
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
    function mark:paintTo(bb, x, y)
        local r = math.floor(size / 2)
        local cx, cy = x + r, y + r
        bb:paintCircle(cx, cy, r, statusInk())
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
function Book.downloadMark(ch)
    local size, inset = Theme.px(18), Theme.px(Theme.current().space.xs)
    return circleMark("check", inset, math.max(0, ch - size - inset))
end

--- 右下角「更多」：实心圆 + more_horiz，贴边留缝。
---@param cw number 封面宽度，单位像素
---@param ch number 封面高度，单位像素
---@return table
function Book.moreMark(cw, ch)
    local size, inset = Theme.px(18), Theme.px(Theme.current().space.xs)
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
function Book.openingBar(cw, ch)
    local t = Theme.current()
    local bar_h = Theme.px(t.control.icon)
    local text = Text.line("caption", _("正在打开"), { color = t.color.page })
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
    function bar:paintTo(bb, x, y)
        bb:paintRect(x, y, cw, bar_h, statusInk())
        local tz = self.text:getSize()
        self.text:paintTo(
            bb,
            x + math.floor((cw - tz.w) / 2),
            y + math.floor((bar_h - tz.h) / 2)
        )
    end
    --- 释放条带拥有的文字控件。
    function bar:free()
        self.text:free()
    end
    bar.overlap_offset = {
        0,
        math.max(0, math.floor((ch - bar_h) / 2)),
    }
    return bar
end

--- 封面 widget。
--- opts.badge: 未读且有进度时叠右上角百分比
--- opts.ribbon: 已读时叠右上角「已读」绑带
--- opts.download: 已本地下载时叠左下角勾（口径见 BookDB.downloadedClause）
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
function Book.cover(plugin, source, book, cw, ch, opts)
    opts = opts or {}
    local title = Book.title(book)
    local pct = Book.pct(book)
    local req
    local cached_cover
    if type(book) == "table" and type(book.stable_id) == "string"
        and type(book.source_id) == "string" and book.source_id ~= "" then
        local cached = Paths.coverPath(book.stable_id, book.source_id)
        if lfs.attributes(cached, "mode") == "file" then
            cached_cover = cached
        end
    end
    -- 显式 src（刮削候选）> 本地封面 > 远程链接：本地已落盘就不再为同一本书走网络。
    if type(opts.src) == "string" and opts.src ~= "" then
        req = { url = opts.src, headers = opts.headers }
    elseif cached_cover then
        req = { url = cached_cover }
    elseif type(book) == "table" and type(book.cover_url) == "string" and book.cover_url ~= "" then
        req = { url = book.cover_url, headers = book.cover_headers }
    elseif type(book) == "table" and type(book.cover) == "string" and book.cover ~= "" then
        req = { url = book.cover, headers = book.cover_headers }
    end
    if not req and type(book) == "table" and type(book.stable_id) == "string" then
        local sid = book.source_id
        local owner = source
        if type(sid) == "string" and sid ~= "" and (not source or source.id ~= sid) then
            owner = require("source.registry").resolve(sid)
        end
        if owner and type(owner.coverRequest) == "function" then
            req = select(1, owner:coverRequest(book))
        end
    end
    local t = Theme.current()
    local style = opts.shadow == false and t.image or t.raised
    -- 内边距只让出边框：Box 先画边框再画子件，图贴着边框内沿。
    local cover_pad = Theme.px(style.border or 0)
    local cover_w = math.max(Theme.px(16), cw - cover_pad * 2)
    local cover_h = math.max(Theme.px(24), ch - cover_pad * 2)
    local on_ready = opts.on_ready
    local image = Image.widget{
        src = req and req.url or nil,
        headers = req and req.headers or nil,
        width = cover_w,
        height = cover_h,
        alpha = false,
        -- 封面框比 2:3 宽（格子留给封面拉宽）时拉伸铺满，免得框里留白边。
        stretch = cover_w * 3 > cover_h * 2 + 2,
        style = {},
        fallback = PlainCover:new{
            title = title,
            author = Book.author(book),
            width = cover_w,
            height = cover_h,
        },
        fallback_src = cached_cover and cached_cover ~= (req and req.url) and cached_cover or nil,
        on_ready = function(path)
            persistCover(book, path)
            if on_ready then on_ready(path) end
        end,
    }
    local cover = Box:new{
        style = style,
        padding = cover_pad,
        image,
    }
    -- 已读与进度互斥；下载状态由查询时带出（book.downloaded）。
    local read = Book.isRead(book)
    local show_read = opts.ribbon and read
    local show_pct = opts.badge and not read and pct > 0
    local show_dl = opts.download and book.downloaded
    local show_more = opts.more
    if show_read or show_pct or show_dl or show_more then
        local overlays = {
            dimen = Geom:new{ w = cw, h = ch },
            show_parent = opts.show_parent,
            cover,
        }
        if show_read then
            overlays[#overlays + 1] = Book.readRibbon(cw)
        elseif show_pct then
            overlays[#overlays + 1] = Book.progressBadge(cw, pct)
        end
        if show_dl then
            overlays[#overlays + 1] = Book.downloadMark(ch)
        end
        if show_more then
            local mark = Book.moreMark(cw, ch)
            if type(opts.more) == "function" then
                local mz = mark:getSize()
                local tap = Book.tappable(mz.w, mz.h, opts.more)
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

--- 作者行字号：比书名小 1 号。
---@return table
local function authorFace()
    return Theme.face("xx_smallinfofont", math.max(8, Theme.current().font.caption - 1))
end

--- 小字号（作者 / 状态行）一行的高度。
---@return number
local function smallLineH()
    local line = Text.line("caption", "M", { face = authorFace() })
    local h = line:getSize().h
    line:free()
    return h
end

--- 作者行上方的缝：紧跟书名时只留 1px，否则（直接在封面或状态行下）留常规间距。
---@param with_title boolean|nil
---@return number
local function authorGap(with_title)
    return with_title and 0 or Theme.px(Theme.current().space.xs)
end

--- 作者行占用的高度（含上方的缝）。
---@param with_title boolean|nil
---@return number
local function authorExtra(with_title)
    return authorGap(with_title) + smallLineH()
end

--- 封面下说明占用的高度：状态行（show_status）、书名各一行，show_author 再加一行。都不要时为 0。
---@param show_title boolean|nil 缺省显示
---@param show_author boolean|nil 缺省不显示
---@param show_status boolean|nil 缺省不显示（封面下方的进度 / 已读 / 详情按钮行）
---@return number
function Book.captionExtra(show_title, show_author, show_status)
    local gap = Theme.px(Theme.current().space.xs)
    local total = show_author and authorExtra(show_title ~= false) or 0
    -- 状态行与作者同字号；状态行贴封面，书名紧跟状态行。
    if show_status then total = total + Theme.px(2) + smallLineH() end
    if show_title ~= false then
        local line = Text.line("caption", "M")
        total = total + (show_status and 0 or gap) + line:getSize().h
        line:free()
    end
    return total
end

--- 纯书籍卡片：封面，其下书名，作者仅在 opts.show_author 时出现。
--- opts.show_title 缺省显示；opts.slot_w 缺省等于封面宽。其余 opts 交给封面（角标、更多、阴影）。
--- opts.status_row 为真时封面下多一行（Kobo 风格：左 opts.status_text 或 opts.status_pct 进度条，右 opts.status_more 的「更多」，可点）。
---@param plugin table|nil
---@param source table|nil
---@param book table|nil
---@param cw number
---@param ch number
---@param opts table|nil
---@return table widget
---@return number height
---@return table cover 封面本体，打开中的状态条叠在这上面
function Book.widget(plugin, source, book, cw, ch, opts)
    opts = opts or {}
    local slot_w = opts.slot_w or cw
    local show_title = opts.show_title ~= false
    local show_author = opts.show_author == true
    local cover = select(1, Book.cover(plugin, source, book, cw, ch, opts))
    local kids = {
        align = "center",
        CenterContainer:new{ dimen = Geom:new{ w = slot_w, h = ch }, cover },
    }
    local t = Theme.current()
    local gap = Theme.px(t.space.xs)
    if opts.status_row then
        local row_h = smallLineH()
        local size = t.font.caption - 1
        local icon_w = opts.status_more and Theme.px(size) + gap or 0
        local left_w = cw - icon_w
        local left
        if opts.status_pct then
            left = CenterContainer:new{
                dimen = Geom:new{ w = left_w, h = row_h },
                require("ui.themes.widgets.progress"):new{ width = left_w - gap, percent = opts.status_pct },
            }
        else
            left = Text.line("caption", opts.status_text or "", { width = left_w, face = authorFace() })
        end
        local row = HorizontalGroup:new{ LeftContainer:new{ dimen = Geom:new{ w = left_w, h = row_h }, left } }
        if opts.status_more then
            local icon = CenterContainer:new{
                dimen = Geom:new{ w = icon_w, h = row_h },
                Icon.widget{ name = "more_horiz", size = size, color = Blitbuffer.Color8(t.color.ink), box = false },
            }
            local tap = Book.tappable(icon_w, row_h, opts.status_more)
            tap[1] = icon
            row[#row + 1] = tap
        end
        kids[#kids + 1] = VerticalSpan:new{ width = Theme.px(2) }
        kids[#kids + 1] = CenterContainer:new{ dimen = Geom:new{ w = slot_w, h = row_h }, row }
    end
    if show_title then
        kids[#kids + 1] = VerticalSpan:new{ width = opts.status_row and 0 or gap }
        kids[#kids + 1] = CenterContainer:new{
            dimen = Geom:new{ w = slot_w, h = Book.captionExtra(true, false) - gap },
            Text.line("caption", Book.title(book), { width = slot_w }),
        }
    end
    if show_author then
        local author = Book.author(book)
        kids[#kids + 1] = VerticalSpan:new{ width = authorGap(show_title) }
        kids[#kids + 1] = CenterContainer:new{
            dimen = Geom:new{ w = slot_w, h = authorExtra(show_title) - authorGap(show_title) },
            Text.line("caption", author ~= "" and author or _("未知作者"), {
                width = slot_w, color = t.color.muted, face = authorFace(),
            }),
        }
    end
    local group = VerticalGroup:new(kids)
    return group, group:getSize().h, cover
end

return Book
