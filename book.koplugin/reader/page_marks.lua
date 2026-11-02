--[[--
阅读页页内标记层：每个 ReaderUI 一个实例，独占一个 view module 和一个全屏点按区；
各功能（X-Ray 实体、微信段评…）经 ``PageMarks.add`` 登记为图层，每帧交出屏上标记，由这里统一绘制、互斥、分发点按。

互斥：同一行文字只归一层。按「原生自有划线 → priority 小的图层 → 同层先交出的标记」依次占位，
后来者扣掉同行已占的横向区间，只画剩余段；点按只认实际画出的段，因此不存在重叠歧义。

点按区不与原生划线点按（readerhighlight_tap）建依赖：KOReader 的 DepGraph 对无依赖的区按登记先后排序，
原生划线在 ReaderUI 初始化时登记，自己的划线因此始终先于这里；未命中返回 false，继续原生翻页。

@module koplugin.book.reader.page_marks
--]]

local Guard = require("ui.guard")

--- 一条页内标记。
---@class PageMark
---@field boxes table[] 屏幕框（每行一段）
---@field solid boolean|nil 实线下划线（缺省虚线）
---@field badge string|nil 有则不画下划线，在末行文字右侧画带这行字的气泡（只用最后一个框），点按气泡
---@field tap fun() 点按回调

--- 标记图层：每帧调用 ``marks``，返回当前屏上标记（无则空表）。
---@class PageMarkLayer
---@field marks fun(self: PageMarkLayer): PageMark[]
---@field paint fun(self: PageMarkLayer, bb: any)|nil 可选：自绘内容（如注音），不占位
---@field tap (fun(self: PageMarkLayer, pos: table): boolean|nil)|nil 可选：自绘内容的点按，所有标记都没命中后才问；命中返回 true

---@class PageMarks
---@field ui table ReaderUI
---@field layers { id: string, priority: number, layer: PageMarkLayer }[]
---@field painted { mark: PageMark, pieces: table[] }[] 上一帧实际画出的段
local PageMarks = {}
PageMarks.__index = PageMarks

--- 扣除后窄于此宽度的碎段不画。
local MIN_PIECE = 4

---@param ui table ReaderUI
---@return number, number
function PageMarks.screenSize(ui)
    local view = ui and ui.view
    if view and view.dimen and view.dimen.w and view.dimen.h then
        return view.dimen.w, view.dimen.h
    end
    local screen = require("device").screen
    return screen:getWidth(), screen:getHeight()
end

--- 读取阅读器实时页码；session.page 可能晚于当前绘制帧。
---@param ui table|nil
---@return number
function PageMarks.currentPage(ui)
    if ui and ui.getCurrentPage then
        local ok, page = pcall(ui.getCurrentPage, ui)
        if ok and tonumber(page) then return tonumber(page) end
    end
    local paging = ui and ui.paging
    if paging and tonumber(paging.current_page) then
        return tonumber(paging.current_page)
    end
    local rolling = ui and ui.rolling
    if rolling and tonumber(rolling.current_page) then
        return tonumber(rolling.current_page)
    end
    local document = ui and ui.document
    if document and document.getCurrentPage then
        local ok, page = pcall(document.getCurrentPage, document)
        if ok and tonumber(page) then return tonumber(page) end
    end
    return 0
end

--- 当前视口缓存键：会话身份 + 屏幕尺寸 + 实时页码 / 滚动位置 + 调用方修订号。
---@param ui table
---@param revision any 调用方数据变了就换值
---@return string|nil 无阅读会话时 nil
function PageMarks.viewKey(ui, revision)
    local cur = require("reader.session").current()
    if not cur or not cur.identity then
        return nil
    end
    local w, h = PageMarks.screenSize(ui)
    local doc = ui and ui.document
    local pos = ""
    if doc and doc.getCurrentPos then
        local ok, p = pcall(doc.getCurrentPos, doc)
        if ok then pos = tostring(p or "") end
    end
    return table.concat({
        cur.identity.source_id, cur.identity.stable_id,
        tostring(cur.identity.chapter_idx or 0), tostring(revision),
        tostring(w or 0), tostring(h or 0), tostring(PageMarks.currentPage(ui)), pos,
    }, "\0")
end

--- 屏幕框与屏幕相交（左上角出屏但仍相交也算）。
---@param box table|nil
---@param width number|nil
---@param height number|nil
---@return boolean
function PageMarks.intersects(box, width, height)
    return box ~= nil and box.x ~= nil and box.y ~= nil and box.w ~= nil and box.h ~= nil
        and box.w > 0 and box.h > 0
        and (not width or (box.x < width and box.x + box.w > 0))
        and (not height or (box.y < height and box.y + box.h > 0))
end

--- 点按命中：排版框与真机触点有偏差，文字上方留半行容错。
---@param pos table
---@param box table
---@return boolean
function PageMarks.hit(pos, box)
    local pad = math.max(8, math.floor((box.h or 0) * 0.5))
    local bottom = box.y + box.h + 2
    -- 线画在行框下面时（字形框贴着墨迹），点按要盖住线。
    if box.line_y and box.line_y > bottom then bottom = box.line_y + 2 end
    return pos.x >= box.x and pos.x <= box.x + box.w
        and pos.y >= box.y - pad and pos.y <= bottom
end

--- 两框同一行：竖向重叠超过较矮者的一半（相邻两行只挨着边，不算）。
---@param a table
---@param b table
---@return boolean
local function sameLine(a, b)
    local overlap = math.min(a.y + a.h, b.y + b.h) - math.max(a.y, b.y)
    return overlap * 2 > math.min(a.h, b.h)
end

--- 段 piece 扣掉占位框 taken 的横向区间，剩余段追加进 out。
---@param piece table
---@param taken table
---@param out table[]
local function cut(piece, taken, out)
    local left, right = piece.x, piece.x + piece.w
    local t_left, t_right = taken.x, taken.x + taken.w
    if t_left >= right or t_right <= left or not sameLine(piece, taken) then
        out[#out + 1] = piece
        return
    end
    if t_left - left >= MIN_PIECE then
        out[#out + 1] = { x = left, y = piece.y, w = t_left - left, h = piece.h }
    end
    if right - t_right >= MIN_PIECE then
        out[#out + 1] = { x = t_right, y = piece.y, w = right - t_right, h = piece.h }
    end
end

--- 标记扣掉已占位的区间，返回剩余段并把它们记为已占。
---@param mark PageMark
---@param taken table[] 已占位的屏幕框（就地追加）
---@return table[]
local function claim(mark, taken)
    local pieces = {}
    for _box_idx, box in ipairs(mark.boxes) do
        local rest = { box }
        for _taken_idx, t in ipairs(taken) do
            local out = {}
            for _piece_idx, piece in ipairs(rest) do cut(piece, t, out) end
            rest = out
        end
        for _piece_idx, piece in ipairs(rest) do pieces[#pieces + 1] = piece end
    end
    for _piece_idx, piece in ipairs(pieces) do taken[#taken + 1] = piece end
    return pieces
end

--- 原生自有划线本帧的屏幕框（ReaderView 先画划线再画 view module，此时已是本帧数据）。
---@param ui table
---@return table[]
local function highlightBoxes(ui)
    local view = ui.view
    if not (view.highlight_visible and view.highlight and view.highlight.visible_boxes) then
        return {}
    end
    local out = {}
    local page = ui.paging and PageMarks.currentPage(ui)
    for _idx, box in ipairs(view.highlight.visible_boxes) do
        -- 分页文档存的是页坐标。
        local rect = page and view:pageToScreenTransform(page, box.rect) or box.rect
        if rect then out[#out + 1] = rect end
    end
    return out
end

-- 行框是排版行高，不是字形。框底贴着下一行框顶，字形在框里的上下留白不对称，
-- 线画在框底就会偏上或偏下。按已画好的正文像素，把线放在本行墨迹底和下一行墨迹顶的正中。
local SAMPLE_MAX = 6
local MIN_SAMPLE_W = 12

---@param bb any
---@param x number
---@param y number
---@return number|nil
local function luminance(bb, x, y)
    if x < 0 or y < 0 or x >= bb:getWidth() or y >= bb:getHeight() then return nil end
    local color = bb:getPixel(x, y)
    local gray = color and color.getColor8 and color:getColor8()
    return gray and gray.a
end

---@param a number
---@param dark boolean 夜间反色时墨迹是亮的
---@return boolean
local function isInk(a, dark)
    if dark then return a < 128 end
    return a > 128
end

---@param bb any
---@param x number
---@param w number
---@param y number
---@param dark boolean
---@return boolean
local function rowHasInk(bb, x, w, y, dark)
    local step = math.max(1, math.floor(w / 5))
    for px = x, x + w - 1, step do
        local a = luminance(bb, px, y)
        if a and isInk(a, dark) then return true end
    end
    return false
end

--- 行框里墨迹的首行、末行（屏幕 y）。
---@param bb any
---@param rect table
---@param dark boolean
---@return number|nil
---@return number|nil
local function inkEdges(bb, rect, dark)
    local y1 = rect.y + rect.h - 1
    local first
    for y = rect.y, y1 do
        if rowHasInk(bb, rect.x, rect.w, y, dark) then first = y; break end
    end
    if not first then return nil, nil end
    for y = y1, first, -1 do
        if rowHasInk(bb, rect.x, rect.w, y, dark) then return first, y end
    end
    return nil, nil
end

--- 行框下方、一行高以内的下一处墨迹。
---@param bb any
---@param rect table
---@param dark boolean
---@return number|nil
local function nextInk(bb, rect, dark)
    local y0 = rect.y + rect.h
    local y1 = math.min(bb:getHeight() - 1, y0 + rect.h - 1)
    for y = y0, y1 do
        if rowHasInk(bb, rect.x, rect.w, y, dark) then return y end
    end
end

--- 笔画顶边，使整段笔画的中心落在 last 与 nxt 两行墨迹的正中。
---@param last number
---@param nxt number
---@param thick number
---@return number
local function strokeTop(last, nxt, thick)
    return math.floor((last + nxt - (thick - 1)) / 2)
end

--- 本行自己的上下留白估出来的行距。段前距在行框上沿，比下留白厚一截就不当成下一行的留白。
---@param rect table
---@param first number
---@param last number
---@return number expected
---@return number guessed 估出来的下一行墨迹顶
local function expectedGap(rect, first, last)
    local top_pad = first - rect.y
    local bottom_pad = rect.y + rect.h - 1 - last
    if top_pad > bottom_pad * 2 + 4 then top_pad = bottom_pad end
    return top_pad + bottom_pad, rect.y + rect.h + top_pad
end

---@param values number[]
---@return number
local function median(values)
    table.sort(values)
    return values[math.ceil(#values / 2)]
end

--- 下划线顶边相对行框底边的偏移。量不到（无像素、空白）就贴框底。
---@param bb any
---@param pieces table[]
---@param thick number
---@return number
local function lineDelta(bb, pieces, thick)
    if not (bb.getPixel and bb.getWidth and bb.getHeight) then return -1 end
    local dark = not (bb.getInverse and bb:getInverse() == 1)
    local count = {}
    local pitch, pitch_n
    for _idx, rect in ipairs(pieces) do
        if rect.w >= MIN_SAMPLE_W and rect.h > 0 then
            count[rect.h] = (count[rect.h] or 0) + 1
            if not pitch_n or count[rect.h] > pitch_n then pitch, pitch_n = rect.h, count[rect.h] end
        end
    end
    if not pitch then return -1 end
    local picked = {}
    for _idx, rect in ipairs(pieces) do
        if rect.w >= MIN_SAMPLE_W and math.abs(rect.h - pitch) <= 2 then
            picked[#picked + 1] = rect
        end
    end
    table.sort(picked, function(a, b) return a.w > b.w end)
    local deltas = {}
    for i = 1, math.min(SAMPLE_MAX, #picked) do
        local rect = picked[i]
        local first, last = inkEdges(bb, rect, dark)
        if first and last then
            local expected, guessed = expectedGap(rect, first, last)
            local nxt = nextInk(bb, rect, dark)
            local gap = nxt and nxt - last or 0
            -- 留白很薄（字形框贴着墨迹）时，下一行在框外，一行高以内都算。
            -- 段距比行距厚，不能把线拖进行距下面的空白。
            local limit = expected < 4 and rect.h or expected * 1.5 + 2
            local target = (gap > 0 and gap <= limit) and nxt or guessed
            if target > last then
                deltas[#deltas + 1] = strokeTop(last, target, thick) - (rect.y + rect.h)
            end
        end
    end
    if #deltas == 0 then return -1 end
    return median(deltas)
end

--- 在段底画下划线（缺省虚线）。``delta`` 是相对行框底边的偏移。
---@param bb any Blitbuffer
---@param rect table
---@param solid boolean|nil
---@param delta number
---@param thick number
local function underline(bb, rect, solid, delta, thick)
    local color = require("ffi/blitbuffer").COLOR_DARK_GRAY
    local line_y = rect.y + rect.h + delta
    if line_y < rect.y then line_y = rect.y + rect.h - 1 end
    rect.line_y = line_y
    if solid then
        bb:paintRect(rect.x, line_y, rect.w, thick, color)
        return
    end
    for i = rect.x, rect.x + rect.w - 8, 10 do
        bb:paintRect(i, line_y, 6, thick, color)
    end
end

--- 气泡字号占正文字号的比例。
local BUBBLE_SCALE = 0.55

--- 带抗锯齿地画气泡：圆角矩形 + 左侧菱形尖角的并集轮廓（1px 灰线，内部填白），按有向距离算每个像素的覆盖率再与底色混合。
---@param bb any Blitbuffer
---@param x number 矩形左
---@param y number 矩形上
---@param w number
---@param h number
---@param radius number
---@param tail number 尖角伸出长度
local function paintBubbleShape(bb, x, y, w, h, radius, tail)
    local Blitbuffer = require("ffi/blitbuffer")
    local dark = 0x88
    local cx, cy = x + w / 2, y + h / 2
    local hx, hy = w / 2 - radius, h / 2 - radius
    local bw, bh = bb:getWidth(), bb:getHeight()
    for py = math.max(0, y - 1), math.min(bh - 1, y + h) do
        for px = math.max(0, x - tail - 1), math.min(bw - 1, x + w) do
            local fx, fy = px + 0.5, py + 0.5
            local qx, qy = math.abs(fx - cx) - hx, math.abs(fy - cy) - hy
            local d = math.sqrt(math.max(qx, 0) ^ 2 + math.max(qy, 0) ^ 2) + math.min(math.max(qx, qy), 0) - radius
            local dd = (math.abs(fx - x) + math.abs(fy - cy) - tail) / 1.4142
            if dd < d then d = dd end
            local fill = math.min(1, math.max(0, 0.5 - d))
            local line = math.min(1, math.max(0, 1 - math.abs(d)))
            if fill > 0 or line > 0 then
                local base = bb:getPixel(px, py):getColor8().a
                local v = base * (1 - fill) + 255 * fill
                v = v * (1 - line) + dark * line
                bb:setPixel(px, py, Blitbuffer.Color8(math.floor(v + 0.5)))
            end
        end
    end
end

--- 在末行文字末尾画对话气泡（圆角描边框，左侧一个朝左的小尖角指向文字末），返回点按矩形；超出右边缘就整体左移。
---@param bb any Blitbuffer
---@param box table 末行屏幕框
---@param text string
---@param body_size number|nil 正文字号；气泡字号取其 BUBBLE_SCALE，缺省按行高估
---@return table rect
local function bubble(bb, box, text, body_size)
    local label = require("ui/widget/textwidget"):new{
        text = text,
        face = require("ui/font"):getFace("cfont", math.max(6, math.floor(body_size and body_size * BUBBLE_SCALE or box.h * 0.2))),
        fgcolor = require("ffi/blitbuffer").Color8(0x88),
    }
    local size = label:getSize()
    -- 数字字形只占文本框的 0.165~0.67（中心在 0.42），按字形而不是文本框居中
    local glyph = math.floor(size.h * 0.505 + 0.5)
    local pad = math.max(3, math.floor(glyph * 0.45))
    local w, h = size.w + pad * 2, glyph + pad * 2
    local tail = math.max(3, math.floor(h / 4))
    local radius = math.max(2, math.floor(h / 4))
    local x = math.min(box.x + box.w + 2 + tail, bb:getWidth() - w - 2)
    local cy = box.y + math.floor(box.h / 2)
    local y = cy - math.floor(h / 2)
    paintBubbleShape(bb, x, y, w, h, radius, tail)
    label:paintTo(bb, x + pad, cy - math.floor(size.h * 0.42 + 0.5))
    label:free()
    return { x = x - tail, y = y, w = w + tail, h = h }
end

--- 占位，先不画。下划线的垂直位置要等本帧所有行框都齐了再量。
---@param entry { layer: PageMarkLayer }
---@param taken table[]
---@param batch table[]
local function collectLayer(entry, taken, batch)
    local items = {}
    for _idx, mark in ipairs(entry.layer:marks()) do
        if mark.badge then
            items[#items + 1] = { mark = mark, badge = mark.boxes[#mark.boxes] }
        else
            local pieces = claim(mark, taken)
            if #pieces > 0 then items[#items + 1] = { mark = mark, pieces = pieces } end
        end
    end
    batch[#batch + 1] = { entry = entry, items = items }
end

---@param batch table[]
---@return table[]
local function linePieces(batch)
    local pieces = {}
    for _idx, group in ipairs(batch) do
        for _item_idx, item in ipairs(group.items) do
            if item.pieces then
                for _piece_idx, piece in ipairs(item.pieces) do pieces[#pieces + 1] = piece end
            end
        end
    end
    return pieces
end

--- 画一个图层：下划线、气泡、自绘，记入本帧已画列表。
---@param group { entry: { layer: PageMarkLayer }, items: table[] }
---@param bb any Blitbuffer
---@param delta number
---@param thick number
---@param painted table[]
local function drawGroup(group, bb, delta, thick, painted, body_size)
    for _idx, item in ipairs(group.items) do
        local pieces
        if item.badge then
            pieces = { bubble(bb, item.badge, item.mark.badge, body_size) }
        else
            pieces = item.pieces
            for _piece_idx, piece in ipairs(pieces) do underline(bb, piece, item.mark.solid, delta, thick) end
        end
        if #pieces > 0 then painted[#painted + 1] = { mark = item.mark, pieces = pieces } end
    end
    if group.entry.layer.paint then group.entry.layer:paint(bb) end
end

---@param self table
---@param bb any Blitbuffer
local function paint(self, bb)
    local taken = highlightBoxes(self.ui)
    local batch = {}
    for _idx, entry in ipairs(self.layers) do
        Guard.paint(entry.id .. ".paintTo", collectLayer, entry, taken, batch)
    end
    local thick = require("ui/size").line.thick
    local delta = lineDelta(bb, linePieces(batch), thick)
    local painted = {}
    local font = self.ui.font and self.ui.font.configurable
    local body_size = font and font.font_size
    for _idx, group in ipairs(batch) do
        Guard.paint(group.entry.id .. ".paintTo", drawGroup, group, bb, delta, thick, painted, body_size)
    end
    self.painted = painted
end

--- 作为 view module 被调用。每个图层各自经 guard 隔离，一层画坏不影响其它层；
--- 取框、帧缓冲像素采样这些公共步骤抛错时整个标记层本进程停画，不能带崩每次重绘。
---@param bb any Blitbuffer
function PageMarks:paintTo(bb)
    self.painted = {}
    Guard.paint("book_page_marks.paintTo", paint, self, bb)
end

--- 点按：只认上一帧实际画出的段。
---@param ges table
---@return boolean
function PageMarks:onTap(ges)
    for _idx, item in ipairs(self.painted) do
        for _piece_idx, piece in ipairs(item.pieces) do
            if PageMarks.hit(ges.pos, piece) then
                item.mark.tap()
                return true
            end
        end
    end
    for _idx, entry in ipairs(self.layers) do
        if entry.layer.tap and entry.layer:tap(ges.pos) then return true end
    end
    return false
end

--- 登记标记图层；priority 小的先占位。每个 ReaderUI 首次登记时建实例、挂 view module 与点按区。
---@param ui table ReaderUI
---@param id string 图层名（也是 guard 标签前缀）
---@param priority number
---@param layer PageMarkLayer
---@return PageMarks
function PageMarks.add(ui, id, priority, layer)
    local self = ui._book_page_marks
    if not self then
        self = setmetatable({ ui = ui, layers = {}, painted = {} }, PageMarks)
        ui._book_page_marks = self
        ui.view:registerViewModule("book_page_marks", self)
        ui:registerTouchZones({ {
            id = "book_page_marks_tap",
            ges = "tap",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            overrides = {
                "tap_forward",
                "tap_backward",
                "readerfooter_tap",
                "readermenu_tap",
            },
            handler = function(ges) return Guard.call("page marks tap", self.onTap, self, ges) end,
        } })
    end
    self.layers[#self.layers + 1] = { id = id, priority = priority, layer = layer }
    table.sort(self.layers, function(a, b) return a.priority < b.priority end)
    return self
end

return PageMarks
