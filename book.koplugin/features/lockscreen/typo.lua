--[[--
锁屏背景：文字海报。只用文字、细线和带颗粒的浅灰巨字排版，适合墨水屏（纯灰阶、大块留白、无渐变）。

文字来自全库划线（随机挑短句），没有划线时用内置句子；书名作者小字署名。
版式（对照参考海报）：
- horizontal：首句粗体大字，中段小字，灰色短线，末句放大压底（「我是大学生，不要对我——哇啦哇啦！」）
- vertical：竖排右起、分句成列、列中关键词放大；左侧颗粒浅灰巨字（单字时压在列后）
- backdrop：分句左上排列，底部颗粒浅灰关键词巨字出血
- scatter：分句居中排列，几个候选词做浅灰巨字散落在背景
- collage：拼贴海报，作者名颗粒灰字 + 行内放大关键词 + 竖排书名 + 细线分栏小字
断行按词（不拆词、不拆关键词）+ 避头尾 + 句末标点悬挂；短句放大填满版心。
plan() 只算绘制指令（可单测），paint 才碰字体和 BlitBuffer。

@module koplugin.book.features.lockscreen.typo
--]]

local MoonSettings = require("utils.settings")
local T = require("features.lockscreen.typo_text")
local _ = require("gettext")

local M = {}

local DEFAULT_STYLE = "random"
local BLACK, INK, GRAY, RULE = 0x00, 0x22, 0x66, 0x88
-- 颗粒巨字的基准灰：背景字浅、拼贴里的作者名深
local PALE, SMOKE = 0xC8, 0x70

local STYLE_IDS = { "horizontal", "vertical", "backdrop", "scatter", "collage" }

-- 没有划线时的句子（自撰，非译文）。
M.FALLBACK = {
    { text = "我们每个人，都对所有人负有罪责。", title = "月读", author = "" },
    { text = "人一旦习惯了痛苦，痛苦也就成了他的家。", title = "月读", author = "" },
    { text = "清醒是一种病，一种真正的、彻头彻尾的病。", title = "月读", author = "" },
    { text = "我怕的不是死，而是配不上我所受的苦难。", title = "月读", author = "" },
}

local function fmt(n) return math.floor(n + 0.5) end

--- 拼署名：——《书名》 作者。
---@param q table
---@return string
function M.attribution(q)
    local parts = {}
    if q.title and q.title ~= "" then parts[#parts + 1] = "《" .. q.title .. "》" end
    if q.author and q.author ~= "" then parts[#parts + 1] = q.author end
    return #parts > 0 and "—— " .. table.concat(parts, " ") or ""
end

local function textOp(ops, s, x, y, size, gray, bold, grain)
    ops[#ops + 1] = { t = "text", s = s, x = fmt(x), y = fmt(y), size = fmt(size), gray = gray, bold = bold,
        grain = grain or nil }
end

local function rectOp(ops, x, y, w, h, gray)
    ops[#ops + 1] = { t = "rect", x = fmt(x), y = fmt(y), w = math.max(1, fmt(w)), h = math.max(1, fmt(h)), gray = gray }
end

local function dateLine() return os.date("%Y.%m.%d") end

--- 一行拆成普通段与关键词段。
local function runs(line, kw)
    local out, pos = {}, 1
    if kw and kw ~= "" then
        while true do
            local a, b = line:find(kw, pos, true)
            if not a then break end
            if a > pos then out[#out + 1] = { line:sub(pos, a - 1), false } end
            out[#out + 1] = { kw, true }
            pos = b + 1
        end
    end
    if pos <= #line then out[#out + 1] = { line:sub(pos), false } end
    return out
end

--- 排版上下文：measure + 行内放大关键词（kscale > 1 时）。
local function newCtx(measure, kw, kscale)
    local c = { measure = measure, kw = kw, kscale = kscale or 1 }
    local emph = c.kscale > 1 and kw or nil
    function c.unitW(u, size, bold)
        if emph and u == emph then return measure(u, size * c.kscale, bold) end
        return measure(u, size, bold)
    end
    --- 行宽，句末悬挂标点不计。
    function c.lineW(line, size, bold)
        local chars = T.chars(line)
        local hang = chars[#chars]
        local wsum = 0
        for _idx, r in ipairs(runs(line, emph)) do
            wsum = wsum + measure(r[1], r[2] and size * c.kscale or size, bold)
        end
        if hang and T.NO_START[hang] then wsum = wsum - measure(hang, size, bold) end
        return wsum
    end
    function c.big(line, size)
        return (emph and line:find(emph, 1, true)) and size * c.kscale or size
    end
    --- 分句成行，每句再按词断行；关键词不拆开。
    function c.wrap(text, width, size, bold)
        local lines = {}
        for _idx, cl in ipairs(T.clauses(text)) do
            for _i, l in ipairs(T.breakLines(cl, width, function(u) return c.unitW(u, size, bold) end, kw)) do
                lines[#lines + 1] = l
            end
        end
        return lines
    end
    function c.height(lines, size, lh)
        local hsum = 0
        for _idx, l in ipairs(lines) do hsum = hsum + c.big(l, size) * lh end
        return hsum
    end
    --- 从 max 起每次缩 5%，直到每行不超宽、总高放得进 max_h。
    function c.fit(text, width, max_size, min_size, max_h, lh, bold)
        local size = max_size
        while true do
            local lines = c.wrap(text, width, size, bold)
            local ok = c.height(lines, size, lh) <= max_h
            for _idx, l in ipairs(lines) do
                if c.lineW(l, size, bold) > width then ok = false end
            end
            if ok or size <= min_size then return fmt(size), lines end
            size = math.max(min_size, size * 0.95)
        end
    end
    --- 画一行（关键词放大、与正文同基线）；返回行顶到下一行顶的高度。
    function c.draw(ops, line, x, y, size, lh, gray, bold)
        local big = c.big(line, size)
        for _idx, r in ipairs(runs(line, emph)) do
            local s = r[2] and size * c.kscale or size
            textOp(ops, r[1], x, y + (big - s) * 0.88, s, gray, bold)
            x = x + measure(r[1], s, bold)
        end
        return big * lh
    end
    --- 宽度刚好填满 width 的单行字号。
    function c.fill(line, width, bold)
        return width / math.max(1, c.lineW(line, 100, bold)) * 100
    end
    return c
end

--- 颗粒巨字：逐字横排（出血允许）。
local function giantRow(ops, word, x, y, g, gray)
    for _idx, ch in ipairs(T.chars(word)) do
        textOp(ops, ch, x, y, g, gray, true, true)
        x = x + g
    end
end

local function caption(ops, q, x, y, size, measure, align_right, w)
    local att = M.attribution(q)
    if att == "" then return end
    if align_right then x = w - x - measure(att, size, false) end
    textOp(ops, att, x, y, size, GRAY, false)
end

local LAYOUTS = {}

function LAYOUTS.horizontal(q, w, h, measure)
    local ops, m = {}, w * 0.1
    local inner = w - m * 2
    local c = newCtx(measure, q.keyword)
    local cs = T.clauses(q.body)
    local body, kw = q.body, q.keyword
    -- 压底大字：关键词到句末不长（≤ 6 字）就从关键词断开；否则末句不长（≤ 8 字）用末句；再不行末句两行
    local tail
    local last = cs[#cs] or body
    local a = kw and body:find(kw, #body - #last + 1, true)
    if a and a > 1 and #T.chars(body:sub(a)) <= 6 then
        tail = body:sub(a)
    elseif #cs >= 2 then
        tail = last
    end
    local rest = tail and body:sub(1, #body - #tail) or body
    local rc = T.clauses(rest)
    local head = rc[1] or body
    local mid = #rc > 1 and table.concat(rc, "", 2) or nil
    local ts, tlines = 0, {}
    if tail then
        ts, tlines = c.fit(tail, inner, math.min(w * 0.19, c.fill(tail, inner, true)), w * 0.06, h * 0.3, 1.15, true)
        if #T.chars(tail) > 8 then
            ts, tlines = c.fit(tail, inner, w * 0.15, w * 0.06, h * 0.3, 1.15, true)
            -- 两行时均分，别让第二行只剩一两个字
            if #tlines == 2 then
                local even = c.lineW(tail, ts, true) / 2 * 1.12
                local bl = T.breakLines(tail, even, function(u) return c.unitW(u, ts, true) end, kw)
                if #bl == 2 then tlines = bl end
            end
        end
    end
    -- 首句比压底大字小一档，层次才拉得开
    local hcap = tail and math.min(w * 0.12, ts * 0.62) or w * 0.15
    local hs, hlines = c.fit(head, inner, math.min(hcap, c.fill(head, inner, true)),
        w * 0.05, h * 0.3, 1.25, true)
    local ms, mlines = 0, {}
    if mid then ms, mlines = c.fit(mid, inner, math.max(w * 0.045, hs * 0.5), w * 0.034, h * 0.2, 1.45, true) end
    local gap = hs * 0.3
    local total = c.height(hlines, hs, 1.25) + (mid and gap + c.height(mlines, ms, 1.45) or 0)
        + (tail and gap * 2.5 + c.height(tlines, ts, 1.15) or 0)
    local y = math.max(m, (h - total) / 2 - h * 0.03)
    for _idx, l in ipairs(hlines) do y = y + c.draw(ops, l, m, y, hs, 1.25, BLACK, true) end
    if mid then
        y = y + gap * 0.3
        for _idx, l in ipairs(mlines) do y = y + c.draw(ops, l, m, y, ms, 1.45, BLACK, true) end
    end
    if tail then
        y = y + gap * 0.7
        rectOp(ops, m, y, inner * 0.2, math.max(2, w * 0.0025), RULE)
        y = y + gap * 1.5
        for _idx, l in ipairs(tlines) do y = y + c.draw(ops, l, m - ts * 0.03, y, ts, 1.15, BLACK, true) end
    end
    caption(ops, q, m, h - m * 0.9 - w * 0.024, w * 0.024, measure)
    return ops
end

function LAYOUTS.vertical(q, w, h, measure)
    local ops, m = {}, w * 0.1
    local kw = q.keyword
    local kchars = T.chars(kw or "")
    local n = #kchars
    local kscale = 1.35
    local col_h = h * 0.68
    -- 巨字：多字时左侧竖立出血，单字时压在列后偏左下
    local g, side = 0, 0
    if n == 1 then
        g = w * 0.62
        textOp(ops, kchars[1], w * 0.12, h * 0.4, g, PALE, true, true)
    elseif n > 1 then
        g = math.min(w * 0.44, h * 0.96 / n)
        local gy = (h - n * g) / 2
        for i, ch in ipairs(kchars) do textOp(ops, ch, -g * 0.06, gy + (i - 1) * g, g, PALE, true, true) end
        side = g * 0.82
    end
    local avail_w = w - m * 2 - side
    local function count(u) return #T.chars(u) * (u == kw and kscale or 1) end
    local function colLen(col)
        local n_ = 0
        for _idx, r in ipairs(runs(col, kw)) do n_ = n_ + count(r[1]) end
        return n_
    end
    local size, cols = w * 0.085, {}
    while true do
        local rows = math.max(2, math.floor(col_h / (size * 1.04)))
        cols = {}
        for _idx, cl in ipairs(T.clauses(q.body)) do
            for _i, col in ipairs(T.breakLines(cl, rows, count, kw)) do cols[#cols + 1] = col end
        end
        if #cols * size * 1.65 <= avail_w or size <= w * 0.035 then break end
        size = size * 0.95
    end
    local pitch = size * 1.65
    -- 列间错落：第二列起逐列下移（至多 0.9 字，放不下就收紧），整体垂直居中
    local stagger = size * 0.9
    if #cols > 1 then
        local longest = 0
        for _idx, col in ipairs(cols) do longest = math.max(longest, colLen(col) * size * 1.04) end
        stagger = math.max(0, math.min(stagger, (h - m * 1.6 - longest) / (#cols - 1)))
    end
    local maxh = 0
    for i, col in ipairs(cols) do
        maxh = math.max(maxh, (i - 1) * stagger + colLen(col) * size * 1.04)
    end
    local top = math.max(m * 0.8, (h - maxh) / 2)
    local right = side > 0 and w - m or (w + #cols * pitch - (pitch - size)) / 2
    for i, col in ipairs(cols) do
        local x = right - size - (i - 1) * pitch
        local y = top + (i - 1) * stagger
        for _idx, r in ipairs(runs(col, kw)) do
            local s = r[2] and size * kscale or size
            for _i, ch in ipairs(T.chars(r[1])) do
                textOp(ops, T.vertical(ch), x - (s - size) / 2, y, s, BLACK, true)
                y = y + s * 1.04
            end
        end
    end
    caption(ops, q, m, h - m * 0.9 - w * 0.024, w * 0.024, measure, true, w)
    return ops
end

function LAYOUTS.backdrop(q, w, h, measure)
    local ops, m = {}, w * 0.1
    local inner = w - m * 2
    local kchars = T.chars(q.keyword)
    local n = #kchars
    local g = math.min(w * 1.04 / n, w * 0.6, h * 0.38)
    giantRow(ops, q.keyword, (w - n * g) / 2, h - g * 0.9, g, PALE)
    local c = newCtx(measure, q.keyword)
    local size, lines = c.fit(q.body, inner * 0.9, w * 0.11, w * 0.05, h * 0.42, 1.22, true)
    local y = h * 0.14
    for _idx, l in ipairs(lines) do y = y + c.draw(ops, l, m, y, size, 1.22, BLACK, true) end
    y = y + size * 0.5
    rectOp(ops, m, y, w * 0.08, math.max(2, w * 0.003), BLACK)
    caption(ops, q, m, y + w * 0.025, w * 0.024, measure)
    return ops
end

--- 非颗粒文字的外接框（含署名），给巨字避让用。
local function textBox(ops, measure)
    local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
    for _idx, op in ipairs(ops) do
        if op.t == "text" and not op.grain then
            x0, y0 = math.min(x0, op.x), math.min(y0, op.y)
            x1, y1 = math.max(x1, op.x + measure(op.s, op.size, op.bold)), math.max(y1, op.y + op.size)
        end
    end
    return { x0, y0, x1, y1 }
end

local function hit(a, b)
    return a[1] < b[3] and b[1] < a[3] and a[2] < b[4] and b[2] < a[4]
end
M._hit = hit
M._textBox = textBox

function LAYOUTS.scatter(q, w, h, measure)
    local ops, m = {}, w * 0.1
    local inner = w - m * 2
    local c = newCtx(measure, q.keyword)
    -- 正文栏收窄到六成多，右侧留出放巨字的空白（参考里「勇气」那一列）
    local size, lines = c.fit(q.body, inner * 0.64, w * 0.085, w * 0.045, h * 0.4, 1.32, true)
    local total = c.height(lines, size, 1.32)
    -- 正文略偏上居中，给底部留出铺巨字的地方
    local y = math.max(m, (h - total) / 2 - h * 0.08)
    for i, l in ipairs(lines) do
        if i > 1 and i % 2 == 1 and #lines > 3 then y = y + size * 0.4 end
        y = y + c.draw(ops, l, m, y, size, 1.32, BLACK, true)
    end
    caption(ops, q, m, y + size * 0.3, w * 0.024, measure)
    -- 巨字只放在空白处：避开正文框（外扩一圈）、彼此不叠、整字落在页内（放不下就缩，不出血）
    local tb = textBox(ops, measure)
    local gap = w * 0.03
    local blocked = { { tb[1] - gap, tb[2] - gap, tb[3] + gap, tb[4] + gap } }
    local pad = w * 0.03
    -- 候选位置（按参考：底部、正文右侧、右上、右下、左上），各取一次
    local slots = {
        function(ww, g) return pad, h - pad - g end,
        function(ww, g) return w - pad - ww, (tb[2] + tb[4] - g) / 2 end,
        function(ww, g) return w - pad - ww, pad end,
        function(ww, g) return w - pad - ww, h - pad - g end,
        function(ww, g) return pad, pad end,
    }
    local used = {}
    local placed = {}
    for _idx, word in ipairs(q.words) do
        local n = #T.chars(word)
        local gmax = math.min(w * 0.3, (w - pad * 2) / n)
        local done = false
        local g = gmax
        while not done and g >= w * 0.1 do
            for si, slot in ipairs(slots) do
                if not used[si] then
                    local x, yy = slot(n * g, g)
                    local box = { x, yy, x + n * g, yy + g }
                    local ok = x >= pad - 0.5 and yy >= pad - 0.5 and box[3] <= w - pad + 0.5 and box[4] <= h - pad + 0.5
                    for _i, b in ipairs(blocked) do if ok and hit(box, b) then ok = false end end
                    if ok then
                        used[si], done = true, true
                        blocked[#blocked + 1] = { box[1] - gap, box[2] - gap, box[3] + gap, box[4] + gap }
                        placed[#placed + 1] = { word, x, yy, g }
                        break
                    end
                end
            end
            g = g * 0.92
        end
    end
    -- 巨字先画（在底层），正文后画
    local out = {}
    for _idx, p in ipairs(placed) do giantRow(out, p[1], p[2], p[3], p[4], PALE) end
    for _idx, op in ipairs(ops) do out[#out + 1] = op end
    return out
end

function LAYOUTS.collage(q, w, h, measure)
    local ops, m = {}, w * 0.065
    local inner = w - m * 2
    local small = w * 0.022
    local left_w = inner * 0.6
    local rx = m + left_w + inner * 0.05
    local right_w = w - m - rx
    -- 顶栏
    local no = string.format("NO.%03d", tonumber(os.date("%j")) or 0)
    textOp(ops, no, m, m, small, INK, false)
    local d = dateLine()
    textOp(ops, d, w - m - measure(d, small, false), m, small, INK, false)
    local y = m + small * 1.9
    rectOp(ops, m, y, inner, math.max(2, w * 0.003), BLACK)
    y = y + w * 0.035
    local top = y
    -- 作者名（或书名）颗粒深灰字
    local who = (q.author and q.author ~= "") and q.author or (q.title ~= "" and q.title) or "MOON"
    local plain = newCtx(measure)
    -- 名字不拆行：缩到一行放得下
    local ws = math.min(w * 0.085, plain.fill(who, left_w, true))
    textOp(ops, who, m, y, ws, SMOKE, true, true)
    y = y + ws * 1.12
    y = y + w * 0.03
    -- 正文：行内放大关键词
    local c = newCtx(measure, q.keyword, 1.5)
    local size, lines = c.fit(q.body, left_w, w * 0.07, w * 0.036, h * 0.3, 1.25, true)
    for _idx, l in ipairs(lines) do y = y + c.draw(ops, l, m, y, size, 1.25, BLACK, true) end
    local bottom = math.max(y, top + h * 0.42)
    -- 右栏：两条细竖线夹竖排书名，下方小字
    rectOp(ops, rx - inner * 0.025, top, 1, bottom - top, BLACK)
    local title = q.title ~= "" and q.title or "月读"
    local tchars = T.chars(title)
    local ts = math.min(w * 0.075, right_w * 0.42, (bottom - top - small * 8) / math.max(1, #tchars))
    local ty = top
    for _idx, ch in ipairs(tchars) do
        textOp(ops, T.vertical(ch), w - m - ts, ty, ts, BLACK, true)
        ty = ty + ts * 1.04
    end
    rectOp(ops, w - m - ts * 1.35, top, 1, ty - top, GRAY)
    local cy = top
    local cw = right_w - ts * 1.6
    for _idx, l in ipairs(T.breakLines(q.body, cw, function(u) return measure(u, small, false) end)) do
        if cy > bottom - small * 3 then break end
        textOp(ops, l, rx, cy, small, INK, false)
        cy = cy + small * 1.6
    end
    rectOp(ops, rx, cy + small * 0.6, small * 2.5, 1, BLACK)
    y = bottom + w * 0.04
    rectOp(ops, m, y, inner, 1, BLACK)
    y = y + w * 0.04
    -- 下栏：左关键词大字 + 署名，右小字信息块
    local mid_top = y
    if q.keyword then
        local ks = math.min(w * 0.26, h * 0.16, plain.fill(q.keyword, left_w * 0.95, true))
        textOp(ops, q.keyword, m - ks * 0.03, y, ks, BLACK, true)
        y = y + ks * 1.2
    end
    caption(ops, q, m, y, small, measure)
    y = y + small * 1.8
    rectOp(ops, m, y, small * 2.5, 1, BLACK)
    rectOp(ops, rx - inner * 0.025, mid_top, 1, math.max(y - mid_top, small * 9), BLACK)
    local info = { _("摘自") .. " " .. (q.title ~= "" and "《" .. q.title .. "》" or "—") }
    if q.author ~= "" then info[#info + 1] = q.author end
    info[#info + 1] = string.format("%d %s", #T.chars(q.body), _("字"))
    info[#info + 1] = d
    local iy = mid_top
    for _idx, line in ipairs(info) do
        for _i, l in ipairs(T.breakLines(line, right_w, function(u) return measure(u, small, false) end)) do
            textOp(ops, l, rx, iy, small, INK, false)
            iy = iy + small * 1.6
        end
    end
    -- 页脚
    local by = h - m - small
    rectOp(ops, m, by - small * 0.9, inner, 1, BLACK)
    textOp(ops, "MOON · 月读", m, by, small, INK, true)
    local tail = string.format("%d / %d", tonumber(os.date("%j")) or 0, 365)
    textOp(ops, tail, w - m - measure(tail, small, false), by, small, INK, false)
    return ops
end

--- 版式是否合法（含 random）。
---@param style string|nil
---@return boolean
function M.validStyle(style)
    return style == "random" or LAYOUTS[style] ~= nil
end

---@return string
function M.style()
    local style = MoonSettings.get("features.lockscreen").lock_screen_typo_style
    return M.validStyle(style) and style or DEFAULT_STYLE
end

local LABELS = {
    random = _("随机"), horizontal = _("横排标题"), vertical = _("竖排"),
    backdrop = _("巨字铺底"), scatter = _("散落关键词"), collage = _("拼贴海报"),
}

---@return {text: string, value: string}[]
function M.styleOptions()
    local options = { { text = LABELS.random, value = "random" } }
    for _idx, id in ipairs(STYLE_IDS) do options[#options + 1] = { text = LABELS[id], value = id } end
    return options
end

---@param style string|nil
---@return string
function M.styleLabel(style)
    return LABELS[style] or LABELS[DEFAULT_STYLE]
end

--- 算绘制指令。q = {text, title, author, keyword?}；measure(text, px, bold) 返回像素宽。
---@param style string
---@param q table
---@return table[]|{ w: number, h: number } ops 画布尺寸与绘制指令
function M.plan(style, q, w, h, measure)
    local body = T.strip(q.text)
    local kw = q.keyword or T.keyword(q.text)
    if kw and not body:find(kw, 1, true) then kw = nil end
    local p = { body = body, title = q.title or "", author = q.author or "", keyword = kw }
    -- 巨字版式没有关键词就只剩一段字，改用横排；没有汉字的句子不竖排
    if style == "backdrop" and not kw then style = "horizontal" end
    if style == "vertical" and not body:find("[\228-\233][\128-\191][\128-\191]") then style = "horizontal" end
    if style == "scatter" then
        p.words = {}
        if kw then p.words[1] = kw end
        for _idx, wd in ipairs(T.topWords(body, 4)) do
            if #p.words < 3 and wd ~= kw then p.words[#p.words + 1] = wd end
        end
        if not kw then style = "horizontal" end
    end
    local ops = (LAYOUTS[style] or LAYOUTS.horizontal)(p, w, h, measure)
    ops.w, ops.h = w, h
    return ops
end

local kw_store
local function keywordStore()
    if not kw_store then
        local Paths = require("utils.paths")
        Paths.ensureCacheRoot()
        kw_store = require("luasettings"):open(Paths.cacheDir() .. "/typo_keywords.lua")
    end
    return kw_store
end

--- AI 挑过的关键词（只读缓存，不发请求）；"" 表示 AI 答过但不可用。
---@param text string
---@return string|nil
function M.cachedKeyword(text)
    local kw = keywordStore():readSetting(T.strip(text))
    -- 旧版 validKeyword 按字节剥标点，会把「云」这类字削成半个字符并缓存下来，读到就当没有
    return kw ~= "" and require("utils.text").isValidUtf8(kw) and kw or nil
end

--- AI 回答是否可用：原句里连续出现的 1–6 个字。
---@param answer string|nil
---@param body string
---@return string|nil
function M.validKeyword(answer, body)
    local kept = {}
    for _idx, ch in ipairs(T.chars(answer)) do
        if not (T.isPunct(ch) or ch:match("^%s$")) then kept[#kept + 1] = ch end
    end
    local kw = table.concat(kept)
    local n = #T.chars(kw)
    if n >= 1 and n <= 6 and body:find(kw, 1, true) then return kw end
    return nil
end

--- 后台让 AI 挑关键词并缓存，供下次锁屏用；未配置、离线、已缓存或有【】标记时什么都不做。
---@param text string
function M.prefetchKeyword(text)
    local body = T.strip(text)
    if text:find("【", 1, true) or keywordStore():has(body) then return end
    if not require("ai").isConfigured() or not require("ui/network/manager"):isConnected() then return end
    local messages = {
        { role = "system", content = "从用户给的句子里挑一个最有意境、最能代表句意的词（通常是 2–4 字的名词），"
            .. "必须是原句中连续出现的原文。只输出这个词，不要解释。" },
        { role = "user", content = body },
    }
    require("ai").chat(messages, { max_tokens = 20, temperature = 0 }, function(content, err)
        if not content then
            require("logger").warn("book typo keyword ai failed", err)
            return
        end
        local store = keywordStore()
        store:saveSetting(body, M.validKeyword(content, body) or "")
        store:flush()
    end)
end

local pools = {}
--- 6–max 字的短划线；不传 items 时按 notes 表戳缓存，免得每次锁屏解码全库划线。
---@param max number
---@param items table[]|nil
---@return table[]
function M.shortQuotes(max, items)
    local stamp = not items and require("book.note_db").stamp()
    local hit = pools[max]
    if hit and hit.stamp == stamp then return hit.list end
    local list = {}
    for _idx, item in ipairs(items or require("book.highlights").collectAll()) do
        local n = #T.chars(item.text or "")
        if n >= 6 and n <= max then list[#list + 1] = { text = item.text, title = item.title, author = item.author } end
    end
    if stamp then pools[max] = { stamp = stamp, list = list } end
    return list
end

--- 随机一条短划线（6–60 字）；没有就用内置句子。
---@return table
function M.pickQuote()
    local items = M.shortQuotes(60)
    if #items == 0 then items = M.FALLBACK end
    return items[math.random(#items)]
end

-- ===== 字体 =====

-- 自动挑选：粗衬线（宋体 / 明朝 / Serif CJK）优先；微信读书在线字体里的宋体（思源宋体 syst、京华老宋体、
-- 寒蝉活宋体、方正宋三、方正悠宋）下载后也会被认出。
local AUTO_BOLD = { "Serif.*CJK.*Black", "Serif.*CJK.*Heavy", "Serif.*CJK.*Bold", "SerifSC.*Black", "SerifSC.*Bold",
    "Song.*Bold", "Ming.*Bold", "Mincho.*Bold" }
local AUTO_REGULAR = { "Serif.*CJK.*Regular", "Serif.*CJK.*Medium", "SerifSC.*Regular", "Serif.*CJK", "SerifSC",
    "^syst%.", "OldSong", "HuoSong", "^fzss%.", "^fzys%.", "Song", "song", "Ming", "Mincho", "宋" }
local HEAVY = { "Black", "Heavy", "Bold", "SemiBold" }

---@return string 当前海报字体 id（空 = 自动）
function M.fontId()
    return MoonSettings.get("features.lockscreen").lock_screen_typo_font or ""
end

---@return string
function M.fontLabel()
    local s = MoonSettings.get("features.lockscreen")
    if not s.lock_screen_typo_font or s.lock_screen_typo_font == "" then return _("自动（优先宋体）") end
    return s.lock_screen_typo_font_name or s.lock_screen_typo_font
end

local function exists(path) return require("libs/libkoreader-lfs").attributes(path, "mode") == "file" end

--- 同族粗体：文件名里的 Regular/Medium/Light 换成 Black/Heavy/Bold，或在扩展名前补 -Bold。
---@param path string
---@return string|nil
function M.boldSibling(path)
    local dir, base, ext = path:match("^(.-)([^/]+)(%.[^.]+)$")
    if not base then return nil end
    for _idx, heavy in ipairs(HEAVY) do
        for _i, light in ipairs({ "Regular", "Medium", "Light", "Normal", "Book" }) do
            if base:find(light, 1, true) then
                local cand = dir .. base:gsub(light, heavy, 1) .. ext
                if exists(cand) then return cand end
            end
        end
        local cand = dir .. base .. "-" .. heavy .. ext
        if exists(cand) then return cand end
    end
    return nil
end

local function register(path)
    local FontList = require("fontlist")
    FontList:getFontList()
    for _idx, p in ipairs(FontList.fontlist) do
        if p == path then return path end
    end
    table.insert(FontList.fontlist, 1, path)
    return path
end

local function scanFonts()
    local lfs = require("libs/libkoreader-lfs")
    local root = require("ui.fonts").settingsFontsDir()
    local dirs = { root, require("utils.paths").fontsDir(), "./fonts", "./fonts/noto" }
    if lfs.attributes(root, "mode") == "directory" then
        for name in lfs.dir(root) do
            if name:sub(1, 1) ~= "." and lfs.attributes(root .. "/" .. name, "mode") == "directory" then
                dirs[#dirs + 1] = root .. "/" .. name
            end
        end
    end
    local found = {}
    for _idx, dir in ipairs(dirs) do
        if lfs.attributes(dir, "mode") == "directory" then
            for name in lfs.dir(dir) do
                if name:match("%.[ot]t[fc]$") then found[#found + 1] = dir .. "/" .. name end
            end
        end
    end
    table.sort(found)
    return found
end

local function firstMatch(found, patterns, reject)
    for _idx, pat in ipairs(patterns) do
        for _i, path in ipairs(found) do
            local name = path:match("[^/]+$")
            if name:match(pat) and not (reject and name:match(reject)) then return path end
        end
    end
end

--- 海报字体文件：用户选的字体（找同族粗体，找不到就合成粗体）；未选或文件已不在时自动挑衬线。
---@return string regular, string|nil bold nil 表示粗体要合成
function M.font()
    local id = M.fontId()
    if id ~= "" then
        -- 只要文件路径：faceNameForId 会读整个字体目录的字体信息，几十个大 CJK 字体在 Kindle 上要十几秒
        local path, err = require("ui.fonts").pathForId(id)
        if path then return path, M.boldSibling(path) end
        require("utils.log").warn("book typo font missing, fallback auto", id, err)
    end
    local found = scanFonts()
    local bold = firstMatch(found, AUTO_BOLD)
    local regular = firstMatch(found, AUTO_REGULAR, "Bold") or firstMatch(found, AUTO_REGULAR, "Black")
    if regular and not bold then bold = M.boldSibling(regular) end
    if bold and not regular then regular = bold end
    if not regular then
        regular = "NotoSansCJKsc-Regular.otf"
        bold = firstMatch(found, { "NotoSansCJK.*Bold" })
    end
    return register(regular), bold and register(bold)
end

--- 字体与测量函数：Font:getFace 会按 DPI 放大，这里除回去，让 size 就是物理像素。
---@return fun(px: number, bold: boolean|nil): table face_of, fun(text: string, px: number, bold: boolean|nil): number measure, boolean synthetic 粗体是否合成
function M.metrics()
    local Font = require("ui/font")
    local RenderText = require("ui/rendertext")
    local Screen = require("device").screen
    local scale = Screen:scaleBySize(1000) / 1000
    local regular, bold = M.font()
    local synthetic = bold == nil
    local faces = {}
    local function face(px, b)
        px = math.max(6, fmt(px))
        local file = (b and bold) or regular
        local key = file .. px
        faces[key] = faces[key] or Font:getFace(file, px / scale)
        return faces[key]
    end
    local function measure(text, px, b)
        if px < 8 then return measure(text, 100, b) * px / 100 end
        return RenderText:sizeUtf8Text(0, 100000, face(px, b), text, true, b and synthetic).x
    end
    return face, measure, synthetic
end

-- 坐标哈希噪声（确定性，0..1）：同一张图每次画出来颗粒一样。
local bit = require("bit")
local function noise(x, y)
    local n = bit.bxor(x * 374761393, y * 668265263)
    n = bit.bxor(n, bit.rshift(n, 13)) * 1274126177
    return bit.band(bit.bxor(n, bit.rshift(n, 16)), 0xFFFF) / 0xFFFF
end

--- 颗粒字：先把字形画进离屏灰度图拿覆盖率，再按「基准灰 ± 粗细两级噪声、零星白点」逐点压暗目标，
--- 模拟参考图里石刻 / 印刷的斑驳质感；墨水屏 16 级灰下仍是颗粒而不是色带。
local function paintGrain(bb, op, ox, oy, f, synthetic, cw, ch)
    local Blitbuffer = require("ffi/blitbuffer")
    local RenderText = require("ui/rendertext")
    local ffi = require("ffi")
    local bold = op.bold and synthetic
    local tw = math.ceil(RenderText:sizeUtf8Text(0, 100000, f, op.s, true, bold).x) + 4
    local th = math.ceil(op.size * 1.25)
    local tmp = Blitbuffer.new(tw, th, Blitbuffer.TYPE_BB8) --[[@as BlitBuffer]]
    tmp:fill(Blitbuffer.COLOR_WHITE)
    RenderText:renderUtf8Text(tmp, 0, fmt(op.size * 0.88), f, op.s, true, bold, Blitbuffer.COLOR_BLACK)
    local p = ffi.cast("uint8_t*", tmp.data)
    local stride = tonumber(tmp.stride)
    local x0, y0 = ox + op.x, oy + op.y
    local xmin, ymin = math.max(0, ox), math.max(0, oy)
    local xmax = math.min(bb:getWidth(), ox + (cw or bb:getWidth())) - 1
    local ymax = math.min(bb:getHeight(), oy + (ch or bb:getHeight())) - 1
    local depth = 255 - op.gray
    -- 离屏灰度画布直接按指针读写（逐点 getPixel/setPixel 会造 Color 对象）；其他类型走通用接口
    local dst = bb:getType() == Blitbuffer.TYPE_BB8 and bb:getRotation() == 0 and bb:getInverse() == 0
        and ffi.cast("uint8_t*", bb.data)
    local dstride = dst and tonumber(bb.stride)
    for y = 0, th - 1 do
        local ty = y0 + y
        if ty >= ymin and ty <= ymax then
            for x = 0, tw - 1 do
                local cov = 255 - p[y * stride + x]
                local tx = x0 + x
                if cov > 8 and tx >= xmin and tx <= xmax then
                    local coarse = noise(math.floor(x / 5), math.floor(y / 5))
                    local fine = noise(x, y)
                    local k = 0.78 + coarse * 0.32 + (fine - 0.5) * 0.28
                    if fine < 0.025 or (coarse < 0.07 and fine < 0.5) then k = 0.15 end
                    local v = 255 - math.min(255, depth * k) * cov / 255
                    if dst then
                        local i = ty * dstride + tx
                        if v < dst[i] then dst[i] = fmt(v) end
                    elseif v < bb:getPixel(tx, ty):getColor8().a then
                        bb:setPixel(tx, ty, Blitbuffer.Color8(fmt(v)))
                    end
                end
            end
        end
    end
    tmp:free()
end

--- 把指令画到 bb（偏移 ox, oy）。出血的颗粒字裁在 ops.w × ops.h 内。
function M.paint(bb, ops, ox, oy, face, synthetic)
    local Blitbuffer = require("ffi/blitbuffer")
    local RenderText = require("ui/rendertext")
    for _idx, op in ipairs(ops) do
        if op.t == "rect" then
            bb:paintRect(ox + op.x, oy + op.y, op.w, op.h, Blitbuffer.Color8(op.gray))
        elseif op.grain then
            paintGrain(bb, op, ox, oy, face(op.size, op.bold), synthetic, ops.w, ops.h)
        else
            -- 基线：字号的 0.88，CJK 字面顶贴 y
            RenderText:renderUtf8Text(bb, ox + op.x, oy + op.y + fmt(op.size * 0.88), face(op.size, op.bold), op.s,
                true, op.bold and synthetic, Blitbuffer.Color8(op.gray))
        end
    end
end

--- 全屏背景块：一个离屏 widget。
---@param rect table
---@return table[]
function M.blocks(rect)
    local w = math.max(1, tonumber(rect.w) or 1)
    local h = math.max(1, tonumber(rect.h) or 1)
    local style = M.style()
    if style == "random" then style = STYLE_IDS[math.random(#STYLE_IDS)] end
    local face, measure, synthetic = M.metrics()
    local picked = M.pickQuote()
    -- 渲染只读缓存；AI 在后台挑，下次锁屏才用上，绝不卡锁屏
    local q = { text = picked.text, title = picked.title, author = picked.author, keyword = M.cachedKeyword(picked.text) }
    M.prefetchKeyword(picked.text)
    local ops = M.plan(style, q, w, h, measure)
    T.release()
    local widget = {}
    function widget:getSize() return { w = w, h = h } end
    function widget:paintTo(bb, x, y) M.paint(bb, ops, x, y, face, synthetic) end
    return {{ kind = "widget", widget = widget, x = 0, y = 0, width = w, height = h }}
end

--- 每次锁屏换一句：键每秒都变。
M.cache_key = os.time

return M
