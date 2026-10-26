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
    return pos.x >= box.x and pos.x <= box.x + box.w
        and pos.y >= box.y - pad and pos.y <= box.y + box.h + 2
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

--- 在段底画下划线（缺省虚线）。
---@param bb any Blitbuffer
---@param rect table
---@param solid boolean|nil
local function underline(bb, rect, solid)
    local Blitbuffer = require("ffi/blitbuffer")
    local Size = require("ui/size")
    local color = Blitbuffer.COLOR_DARK_GRAY
    local line_y = rect.y + rect.h - 1
    if solid then
        bb:paintRect(rect.x, line_y, rect.w, Size.line.thick, color)
        return
    end
    for i = rect.x, rect.x + rect.w - 8, 10 do
        bb:paintRect(i, line_y, 6, Size.line.thick, color)
    end
end

--- 在末行文字末尾画对话气泡（圆角框 + 朝下的小尖角指向文字末），返回点按矩形；超出右边缘就整体左移。
---@param bb any Blitbuffer
---@param box table 末行屏幕框
---@param text string
---@return table rect
local function bubble(bb, box, text)
    local Blitbuffer = require("ffi/blitbuffer")
    local dark, white = Blitbuffer.COLOR_DARK_GRAY, Blitbuffer.COLOR_WHITE
    local label = require("ui/widget/textwidget"):new{
        text = text,
        face = require("ui/font"):getFace("cfont", math.max(7, math.floor(box.h * 0.26))),
        fgcolor = dark,
    }
    local size = label:getSize()
    local pad = 5
    local w, h = size.w + pad * 2, size.h
    local tail = 3
    local radius = math.floor(h / 4)
    -- 紧跟段末文字，垂直居中，只描边；尖角在左下
    local x = math.min(box.x + box.w + 4, bb:getWidth() - w - 2)
    local y = box.y + math.floor((box.h - h) / 2) - 1
    bb:paintRoundedRect(x, y, w, h, white, radius)
    bb:paintBorder(x, y, w, h, 1, dark, radius)
    -- 尖角：从底边向下收成一点，顶行擦掉底边的一段再补两条斜边
    local tx = x + radius + tail
    for r = 0, tail do
        local half, row = tail - r, y + h - 1 + r
        if half >= 1 then bb:paintRect(tx - half + 1, row, 2 * half - 1, 1, white) end
        bb:paintRect(tx - half, row, 1, 1, dark)
        bb:paintRect(tx + half, row, 1, 1, dark)
    end
    label:paintTo(bb, x + pad, y)
    label:free()
    return { x = x, y = y, w = w, h = h + tail }
end

--- 画一个图层：逐条占位，画剩余段，记入本帧已画列表。
---@param entry { layer: PageMarkLayer }
---@param bb any Blitbuffer
---@param taken table[]
---@param painted table[]
local function paintLayer(entry, bb, taken, painted)
    for _idx, mark in ipairs(entry.layer:marks()) do
        local pieces
        if mark.badge then
            pieces = { bubble(bb, mark.boxes[#mark.boxes], mark.badge) }
        else
            pieces = claim(mark, taken)
            for _piece_idx, piece in ipairs(pieces) do underline(bb, piece, mark.solid) end
        end
        if #pieces > 0 then painted[#painted + 1] = { mark = mark, pieces = pieces } end
    end
    if entry.layer.paint then entry.layer:paint(bb) end
end

--- 作为 view module 被调用；每个图层各自经 guard 隔离，一层画坏不影响其它层。
---@param bb any Blitbuffer
function PageMarks:paintTo(bb)
    local taken = highlightBoxes(self.ui)
    local painted = {}
    for _idx, entry in ipairs(self.layers) do
        Guard.paint(entry.id .. ".paintTo", paintLayer, entry, bb, taken, painted)
    end
    self.painted = painted
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
