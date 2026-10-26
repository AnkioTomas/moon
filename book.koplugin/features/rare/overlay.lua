--[[--
生僻字注音绘制层：挂在 reader.page_marks 上（只画字，不占位、不接点按）。

每屏：取屏上首末位置 → 逐个可见字走一遍（只走本屏，和书多大无关）→ 各启用词库按阈值（生字本里的不看阈值）
找出每一处命中 → 按命中的字位置取屏幕框 → 在框上方画注音。
不用 findText：它每个词都从本页往后扫几页正文，词多（「全部」档）或书大时会撞上时间预算，后面的字就不注了。
总耗时超过 BUDGET_MS 才停止取框（记日志），正常屏幕远不到。
结果按 PageMarks.viewKey 缓存，翻页 / 改排版 / 改设置（revision）才重算。

@module koplugin.book.features.rare.overlay
--]]

local PageMarks = require("reader.page_marks")
local Perf = require("utils.perf")
local logger = require("utils.log")

-- 子进程里跑，不卡界面；只防异常文档拖死，须小于 Job 的 timeout（30 秒）。
local BUDGET_MS = 20000
-- 每屏最多走的字数 / 注音处数：只防异常文档跑飞，正常一屏远不到。
local MAX_UNITS = 6000
local MAX_HITS = 3000
local CALIBRATE_BOXES = 24
-- 注音用拉丁字体：界面字体若是中文字体（如方正兰亭黑），带声调字母是全角宽，拼音会被拉散。
local FACE = "NotoSans-Regular.ttf"

local Overlay = {}
Overlay.__index = Overlay

-- 改设置 / 换词库时自增，作废所有缓存。
local revision = 0

function Overlay.invalidate()
    revision = revision + 1
    local ui = require("apps/reader/readerui").instance
    if ui and ui.dialog then require("ui/uimanager"):setDirty(ui.dialog, "ui") end
end

--- 注音字号下限（像素）：行间空隙再小也按这个画（宁小勿缺，此时可能贴上一行）。
Overlay.FLOOR = 6
--- 注音与上一行字形底（含英文下伸部）之间至少留的像素。
Overlay.MARGIN = 1

--- 全屏统一字号（像素）：min(正文字号 × ratio, 行间空隙能放下的字号)，不小于 FLOOR。
--- gap = 行距 − 正文字形墨迹高（顶到下伸部底）；注音墨迹高 = size × ann_em。
---@param body_size number 正文字号（像素）
---@param ratio number
---@param gap number|nil 行间空隙（像素）；nil 不限
---@param ann_em number|nil 注音字体墨迹高 / 字号
---@return integer
function Overlay.size(body_size, ratio, gap, ann_em)
    local size = math.floor(body_size * ratio + 0.5)
    if gap and ann_em and ann_em > 0 then
        -- 再减 1：基线取整最多吃掉 1px。
        size = math.min(size, math.floor((gap - Overlay.MARGIN - 1) / ann_em))
    end
    return math.max(Overlay.FLOOR, size)
end

--- 同行相邻注音的最小间距（像素）。
local GAP = 2

--- 纯布局：命中框 → 注音位置。全屏同一字号；注音墨迹底贴着本行字形顶，放在行间空隙里。
--- 行模型：行框底部 pitch 高是本行（段首框更高，多出的是段前距），字形墨迹在本行内 [top, bottom]。
--- 横向夹在屏内；同行相邻的不重叠：在词框内右推，推不下跳过后一个。
---@param hits { ann: string, key: string, box: table }[]
---@param opts { size: integer, pitch: number, top: number, ann_bottom: number, screen_w: number, measure: fun(text: string, size: integer): number }
---@return { text: string, key: string, box: table, x: integer, y: integer, w: number, size: integer }[] y 为基线
function Overlay.layout(hits, opts)
    local out, size = {}, opts.size
    for _idx, hit in ipairs(hits) do
        local box = hit.box
        local w = opts.measure(hit.ann, size)
        local x = math.floor(box.x + (box.w - w) / 2)
        x = math.max(0, math.min(x, opts.screen_w - w))
        local line_top = box.y + box.h - math.min(opts.pitch, box.h)
        local y = math.max(size, math.floor(line_top + opts.top - opts.ann_bottom))
        -- 同行相邻注音不许重叠：在本词框内右推，推不下就跳过这个。
        local prev = out[#out]
        if prev and math.abs((prev.box.y + prev.box.h) - (box.y + box.h)) < opts.pitch / 2 and x < prev.x + prev.w + GAP then
            x = prev.x + prev.w + GAP
            if x + w > math.min(box.x + box.w, opts.screen_w) then x = nil end
        end
        if x then
            out[#out + 1] = { text = hit.ann, key = hit.key, box = box, x = x, y = y, w = w, size = size }
        end
    end
    return out
end

--- 从排好的页面量行距与字形墨迹：pitch = 命中框最矮的高（段首高框被排除）；
--- 在这些框里扫已画好的正文像素，得墨迹相对行顶的最高 / 最低行（多个词合起来，含英文下伸部）。
---@param bb table 已画正文的屏幕 Blitbuffer
---@param boxes table[] 命中词的屏幕框
---@return { pitch: number, top: number, bottom: number }|nil
function Overlay.calibrate(bb, boxes)
    local pitch
    for _idx, box in ipairs(boxes) do pitch = math.min(pitch or box.h, box.h) end
    if not pitch then return nil end
    local W, H = bb:getWidth(), bb:getHeight()
    local top, bottom, scanned = nil, nil, 0
    for _idx, box in ipairs(boxes) do
        -- 逐像素扫很慢：「全部」档命中成百上千，取前几十处足够量出墨迹范围。
        if box.h == pitch and scanned < CALIBRATE_BOXES then
            scanned = scanned + 1
            for y = math.max(0, box.y), math.min(H - 1, box.y + box.h - 1) do
                for x = math.max(0, box.x), math.min(W - 1, box.x + box.w - 1) do
                    if bb:getPixel(x, y):getColor8().a < 128 then
                        top = math.min(top or y - box.y, y - box.y)
                        bottom = math.max(bottom or y - box.y, y - box.y)
                        break
                    end
                end
            end
        end
    end
    if not top then return nil end
    return { pitch = pitch, top = top, bottom = bottom }
end

--- 注音字体文件（KOReader 自带在 fonts/noto/）。
---@return string
local function facePath()
    local dir = require("fontlist").fontdir
    local noto = dir .. "/noto/" .. FACE
    return require("libs/libkoreader-lfs").attributes(noto, "mode") == "file" and noto or dir .. "/" .. FACE
end

local faces = {}
--- 按像素取注音字体（Font:getFace 会按 DPI 再缩放，这里要精确像素）。
---@param px integer
---@return table face
local function annFace(px)
    if not faces[px] then
        local Font = require("ui/font")
        local ok, ftsize = pcall(function()
            return require("ffi/freetype").newFaceSize(facePath(), px)
        end)
        faces[px] = ok and { ftsize = ftsize, hash = FACE .. "@px" .. px, orig_font = FACE, realname = FACE, size = px, orig_size = px }
            or Font:getFace(FACE, px)
    end
    return faces[px]
end
Overlay.annFace = annFace

--- 字形墨迹：基线以上最高 / 以下最深（像素）。缺字的跳过。
---@param ftsize table
---@param codes integer[]
---@return number top, number bottom
local function ink(ftsize, codes)
    local top, bottom = 0, 0
    for _idx, code in ipairs(codes) do
        if ftsize:hasGlyph(code) then
            local g = ftsize:renderGlyph(code)
            top = math.max(top, g.t)
            bottom = math.max(bottom, g.bb:getHeight() - g.t)
        end
    end
    return top, bottom
end
-- 注音：带声调字母、IPA 的升部与下伸部。
local ANN_CODES = { 0x1CE, 0x1D8, 0xC1, 100, 108, 0x2C8, 103, 106, 112, 121, 0x14B, 0x283 }

local ann_ink
--- 注音字体墨迹高 / 字号（em，含声调与下伸部），量一次。
---@return { em: number, bottom_em: number }
function Overlay.annInk()
    if not ann_ink then
        local ok, at, ab = pcall(function()
            local ann = require("ffi/freetype").newFaceSize(facePath(), 100) --[[@as FreeTypeSize]]
            local t, b = ink(ann, ANN_CODES)
            ann:done()
            return t, b
        end)
        ann_ink = ok and { em = (at + ab) / 100, bottom_em = ab / 100 } or { em = 1.3, bottom_em = 0.3 }
    end
    return ann_ink
end

-- 排版尺寸缓存：只在字体 / 字号 / 行距等排版设置变化时重量（翻页不变，字号跨页稳定）。
local calib_key, calib
--- 当前排版设置的键。
---@param document table CreDocument
---@return string
function Overlay.layoutKey(document)
    local c = document.configurable or {}
    return table.concat({ tostring(document.getFontFace and document:getFontFace()),
        tostring(document.getFontSize and document:getFontSize()), tostring(c.line_spacing),
        tostring(c.font_gamma), tostring(c.word_spacing and table.concat(c.word_spacing, ",")) }, "|")
end

---@param ui table ReaderUI
---@return table
function Overlay.new(ui)
    return setmetatable({ ui = ui, key = nil, items = {} }, Overlay)
end

--- xpointer 后移一个字（同一文本节点内偏移 +1）；不是文本偏移形式返回 nil。
---@param xp string
---@return string|nil
local function nextOffset(xp)
    local base, off = xp:match("^(.-%.)(%d+)$")
    if base then return base .. (tonumber(off) + 1) end
end

--- 本屏逐字：从 pos0 起 getNextVisibleChar 走到 pos1（含），每个可见字一个单元 { text, xp, stop }。
--- stop 是该字之后的位置（取框用的终点）。空白不成单元。
---@param document table CreDocument
---@param pos0 string
---@param pos1 string
---@return { text: string, xp: string, stop: string }[]
function Overlay.walk(document, pos0, pos1)
    local units, xp = {}, pos0
    while xp and #units < MAX_UNITS do
        local order = document:compareXPointers(xp, pos1)
        if not order or order < 0 then break end
        local nx = document:getNextVisibleChar(xp)
        local stop = nextOffset(xp) or nx
        local text = stop and document:getTextFromXPointers(xp, stop) or ""
        text = text:gsub("%s+", "")
        if text ~= "" then
            -- 偶有一次取到多个字（节点边界）：只取第一个字，位置仍按这一格。
            units[#units + 1] = { text = text:match("^[%z\1-\127\194-\244][\128-\191]*"), xp = xp, stop = stop }
        end
        if not nx or nx == xp then break end
        xp = nx
    end
    return units
end

--- 本屏命中处的屏幕框（按 y、x 排序）。
---@param self table
---@param units table[] Overlay.walk 的结果
---@param found { i: integer, n: integer, key: string, ann: string }[]
---@param started_at number
---@return { ann: string, key: string, box: table }[]
local function locate(self, units, found, started_at)
    local document = self.ui.document
    local width, height = PageMarks.screenSize(self.ui)
    local hits = {}
    for _idx, f in ipairs(found) do
        if Perf.elapsedMs(started_at) > BUDGET_MS then
            logger.warn("book.rare budget exceeded, drawn", #hits, "of", #found)
            break
        end
        local first, last = units[f.i], units[f.i + f.n - 1]
        for _b, box in ipairs(document:getScreenBoxesFromPositions(first.xp, last.stop, true) or {}) do
            if PageMarks.intersects(box, width, height) then
                hits[#hits + 1] = { ann = f.ann, box = box, key = f.key }
            end
        end
    end
    table.sort(hits, function(a, b)
        if a.box.y ~= b.box.y then return a.box.y < b.box.y end
        return a.box.x < b.box.x
    end)
    return hits
end

--- 本屏命中处的取框（子进程里跑：走字、匹配、取框都是对排好版的文档的重活）。
--- 返回的 hits 只含 { ann, key, box } 纯数据，经 JSON 回主进程。
---@param self table
---@param lexicons RareLexicon[]
---@param level string
---@param force table<string, boolean>|nil
---@return { ann: string, key: string, box: table }[]
local function scanHits(self, lexicons, level, force)
    local document = self.ui.document
    local started_at = Perf.now()
    local width, height = PageMarks.screenSize(self.ui)
    local ok, range = pcall(document.getTextFromPositions, document, { x = 0, y = 0 }, { x = width, y = height }, true)
    if not (ok and range and range.pos0 and range.pos1) then return {} end
    local units = Overlay.walk(document, range.pos0, range.pos1)
    if #units == 0 then return {} end
    local texts = {}
    for i, u in ipairs(units) do texts[i] = u.text end
    local Lexicon = require("features.rare.lexicon")
    local found = {}
    for _idx, lex in ipairs(lexicons) do
        for _f, f in ipairs(Lexicon.scan(lex, texts, Lexicon.threshold(lex, level), force, MAX_HITS - #found)) do
            found[#found + 1] = f
        end
    end
    if #found == 0 then return {} end
    return locate(self, units, found, started_at)
end

--- 命中框 → 注音布局（主进程：要读屏幕像素量字形，量一次按排版设置缓存）。
---@param self table
---@param hits { ann: string, key: string, box: table }[]
---@param bb any 已画好正文的屏幕 Blitbuffer
---@return table[]
local function arrange(self, hits, bb)
    local document = self.ui.document
    local settings = require("utils.settings").get("features.rare")
    local width = PageMarks.screenSize(self.ui)
    local RenderText = require("ui/rendertext")
    local key = Overlay.layoutKey(document)
    if key ~= calib_key then
        local boxes = {}
        for _idx, hit in ipairs(hits) do boxes[#boxes + 1] = hit.box end
        local c = Overlay.calibrate(bb, boxes)
        if not c then return {} end
        calib_key, calib = key, c
        logger.dbg("book.rare calibrate", key, c.pitch, c.top, c.bottom)
    end
    local ann = Overlay.annInk()
    local body = document.getFontSize and document:getFontSize() or 22
    local size = Overlay.size(body, settings.rare_size, calib.pitch - (calib.bottom - calib.top + 1), ann.em)
    return Overlay.layout(hits, {
        size = size, pitch = calib.pitch, top = calib.top,
        ann_bottom = math.ceil(ann.bottom_em * size), screen_w = width,
        measure = function(t, px)
            return RenderText:sizeUtf8Text(0, width, annFace(px), t, true, false).x
        end,
    })
end

local SCAN_DEBOUNCE = 0.2

--- 取消排队的计时器和在飞的子进程。
---@param self table
local function cancelScan(self)
    if self.timer then
        require("ui/uimanager"):unschedule(self.timer)
        self.timer = nil
    end
    if self.job then
        self.job:cancel()
        self.job = nil
    end
    self.scheduled = nil
end

--- 重算本视口注音：防抖后在子进程取框（走字 / 匹配 / 取框不占主线程），
--- 回主进程量字形、排布局并请求重绘。翻页这一帧只排队，不画旧注音。
---@param key string 排队时的视口键
function Overlay:refresh(key)
    local ui = self.ui
    local document = ui.document
    if not (ui.rolling and document and document.getTextFromPositions and document.getNextVisibleChar
        and document.compareXPointers and document.getScreenBoxesFromPositions) then
        self.key = key
        return
    end
    local settings = require("utils.settings").get("features.rare")
    local lexicons = require("features.rare.catalog").active()
    if #lexicons == 0 then
        self.key = key
        return
    end
    local level = settings.rare_level
    -- 生字本读库：只能在主进程取，子进程拿结果副本。
    local force = settings.rare_vocab and require("features.rare.vocab").set() or nil
    local started_at = Perf.now()
    local job = require("workers.job").run(function()
        return scanHits(self, lexicons, level, force)
    end, {
        name = "features.rare.scan",
        kind = "light",
        timeout = 30,
        on_done = function(hits)
            if self.scheduled ~= key then return end
            self.job, self.scheduled = nil, nil
            if ui.document == nil or key ~= PageMarks.viewKey(ui, revision) then return end
            -- 先占住 key：排布局出错时不会每次重绘都重试。
            self.items, self.key = {}, key
            self.items = arrange(self, hits or {}, require("device").screen.bb)
            logger.dbg("book.perf rare.view", Perf.elapsedMs(started_at), "ms items", #self.items)
            if #self.items > 0 then require("ui/uimanager"):setDirty(ui.dialog, "ui") end
        end,
        on_failed = function(err)
            if self.scheduled ~= key then return end
            self.job, self.scheduled = nil, nil
            self.items, self.key = {}, key
            logger.warn("book.rare scan failed", err)
        end,
    })
    if self.scheduled == key and not job.settled then self.job = job end
end

--- PageMarks 图层接口：本层只画不标，marks 为空。
---@return PageMark[]
function Overlay:marks()
    return {}
end

--- PageMarks 绘制钩子（外层已经 Guard.paint）。视口变了只排队，本帧不画旧注音。
---@param bb any Blitbuffer
function Overlay:paint(bb)
    if not require("utils.settings").get("features.rare").rare_enabled then return end
    local key = PageMarks.viewKey(self.ui, revision)
    if not key then return end
    if key ~= self.key then
        self.items, self.key = {}, nil
        if self.scheduled ~= key then
            cancelScan(self)
            self.scheduled = key
            local UIManager = require("ui/uimanager")
            self.timer = require("ui.guard").wrap("rare refresh", function()
                self.timer = nil
                if self.scheduled == key then self:refresh(key) end
            end)
            UIManager:scheduleIn(SCAN_DEBOUNCE, self.timer)
        end
        return
    end
    if #self.items == 0 then return end
    local RenderText = require("ui/rendertext")
    -- 纯黑：灰色在墨水屏上偏淡，小字号注音看不清。
    local color = require("ffi/blitbuffer").COLOR_BLACK
    for _idx, item in ipairs(self.items) do
        RenderText:renderUtf8Text(bb, item.x, item.y, annFace(item.size), item.text, true, false, color)
    end
end

--- 挂到阅读页标记层（priority 30，在 X-Ray、段评之后；本层不占位）。
---@param ui table ReaderUI
function Overlay.install(ui)
    if ui._book_rare_overlay then return end
    ui._book_rare_overlay = Overlay.new(ui)
    PageMarks.add(ui, "rare", 30, ui._book_rare_overlay)
end

return Overlay
