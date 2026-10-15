--[[--
生僻字注音绘制层：挂在 reader.page_marks 上（只画字，不占位、不接点按）。

每屏：取屏上文字 → 各启用词库按阈值找生僻词 → 逐词 findText 取屏幕框 → 在框上方画注音。
没命中的屏只花一次取字 + 查表；有命中时超过 BUDGET 秒就停止取框，剩下的不画。
结果按 PageMarks.viewKey 缓存，翻页 / 改排版 / 改设置（revision）才重算。

@module koplugin.book.features.rare.overlay
--]]

local PageMarks = require("reader.page_marks")
local Perf = require("utils.perf")
local logger = require("utils.log")

local BUDGET_MS = 250
local MAX_WORDS = 80

local Overlay = {}
Overlay.__index = Overlay

-- 改设置 / 换词库时自增，作废所有缓存。
local revision = 0

function Overlay.invalidate()
    revision = revision + 1
    local ui = require("apps/reader/readerui").instance
    if ui and ui.dialog then require("ui/uimanager"):setDirty(ui.dialog, "ui") end
end

--- 纯布局：命中框 → 注音位置。字号取行高 × ratio，宽于框 1.5 倍时缩到不小于六成；
--- 同一行与上一个注音重叠的跳过；横向夹在屏内。
---@param hits { ann: string, box: table }[]
---@param opts { ratio: number, screen_w: number, measure: fun(text: string, size: integer): number }
---@return { text: string, x: integer, y: integer, size: integer }[] y 为基线
function Overlay.layout(hits, opts)
    local out, last = {}, nil
    for _idx, hit in ipairs(hits) do
        local box = hit.box
        local size = math.max(8, math.floor(box.h * opts.ratio + 0.5))
        local w = opts.measure(hit.ann, size)
        local max_w = box.w * 1.5
        if w > max_w then
            local shrunk = math.max(math.floor(size * 0.6), 8, math.floor(size * max_w / w))
            if shrunk < size then
                size = shrunk
                w = opts.measure(hit.ann, size)
            end
        end
        local x = math.floor(box.x + (box.w - w) / 2)
        x = math.max(0, math.min(x, opts.screen_w - w))
        local y = math.max(size, box.y)
        if not (last and last.y == y and x < last.right) then
            out[#out + 1] = { text = hit.ann, x = x, y = y, size = size }
            last = { y = y, right = x + w + 2 }
        end
    end
    return out
end

---@param ui table ReaderUI
---@return table
function Overlay.new(ui)
    return setmetatable({ ui = ui, key = nil, items = {} }, Overlay)
end

--- 英文整词：命中前后紧邻字符不能是字母或撇号（否则是更长单词的一部分）。
---@param document table CreDocument
---@param match { start: string, ["end"]: string }
---@return boolean
function Overlay.wholeWord(document, match)
    local prev = document:getPrevVisibleChar(match.start)
    local before = prev and document:getTextFromXPointers(prev, match.start) or ""
    local next = document:getNextVisibleChar(match["end"])
    local after = next and document:getTextFromXPointers(match["end"], next) or ""
    return not (before:sub(-1):match("[%a']") or after:sub(1, 1):match("[%a']"))
end

--- 当前屏命中词的屏幕框（按 y、x 排序）。
---@param self table
---@param words { key: string, ann: string, ci: boolean }[]
---@return { ann: string, box: table }[]
local function locate(self, words)
    local document = self.ui.document
    local width, height = PageMarks.screenSize(self.ui)
    local started_at = Perf.now()
    local hits = {}
    for _idx, word in ipairs(words) do
        if Perf.elapsedMs(started_at) > BUDGET_MS then
            logger.dbg("book.rare budget exceeded, drawn", #hits)
            break
        end
        for _m, match in ipairs(document:findText(word.key, 0, 0, word.ci, nil, false, 5000, 0) or {}) do
            if not word.ci or Overlay.wholeWord(document, match) then
                for _b, box in ipairs(document:getScreenBoxesFromPositions(match.start, match["end"], true) or {}) do
                    if PageMarks.intersects(box, width, height) then
                        hits[#hits + 1] = { ann = word.ann, box = box }
                    end
                end
            end
        end
    end
    -- findText 会把最后一次命中写进原生 selection，只要坐标。
    if document.clearSelection then document:clearSelection() end
    table.sort(hits, function(a, b)
        if a.box.y ~= b.box.y then return a.box.y < b.box.y end
        return a.box.x < b.box.x
    end)
    return hits
end

--- 重算本屏注音。
---@param self table
---@return table[]
local function compute(self)
    local document = self.ui.document
    if not (self.ui.rolling and document and document.findText and document.getScreenBoxesFromPositions) then
        return {}
    end
    local settings = require("utils.settings").get("features.rare")
    local lexicons = require("features.rare.catalog").active()
    if #lexicons == 0 then return {} end
    local text = require("reader.context").visibleText(self.ui)
    if not text then return {} end
    local Lexicon = require("features.rare.lexicon")
    local words = {}
    for _idx, lex in ipairs(lexicons) do
        for _w, word in ipairs(Lexicon.match(lex, text, Lexicon.threshold(lex, settings.rare_level), MAX_WORDS)) do
            word.ci = lex.lang == "en"
            words[#words + 1] = word
        end
    end
    if #words == 0 then return {} end
    local Font = require("ui/font")
    local RenderText = require("ui/rendertext")
    local width = PageMarks.screenSize(self.ui)
    return Overlay.layout(locate(self, words), {
        ratio = settings.rare_size,
        screen_w = width,
        measure = function(t, size)
            return RenderText:sizeUtf8Text(0, width, Font:getFace("cfont", size), t, true, false).x
        end,
    })
end

--- PageMarks 图层接口：本层只画不标，marks 为空。
---@return PageMark[]
function Overlay:marks()
    return {}
end

--- PageMarks 绘制钩子（外层已经 Guard.paint）。
---@param bb any Blitbuffer
function Overlay:paint(bb)
    if not require("utils.settings").get("features.rare").rare_enabled then return end
    local key = PageMarks.viewKey(self.ui, revision)
    if not key then return end
    if key ~= self.key then
        local started_at = Perf.now()
        self.items = compute(self)
        self.key = key
        logger.dbg("book.perf rare.view", Perf.elapsedMs(started_at), "ms items", #self.items)
    end
    if #self.items == 0 then return end
    local Font = require("ui/font")
    local RenderText = require("ui/rendertext")
    local color = require("ffi/blitbuffer").COLOR_DARK_GRAY
    for _idx, item in ipairs(self.items) do
        RenderText:renderUtf8Text(bb, item.x, item.y, Font:getFace("cfont", item.size), item.text, true, false, color)
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
