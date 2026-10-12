--[[--
页内段评标记：本章他人段评的句子画虚线下划线，点按弹出段评列表。

两种目标，都是「键 + fetch + place」：键变了才重新 fetch，视口变了才重新 place。
- 微信读书章会话：fetch 拉本章热点并在子进程里定位到本章文件；place 只问当前页附近句子的屏幕框。
- 关联了微信书目的本地书（见 ``features.reviews.linked``）：fetch 拉微信目录；place 按当前页拉章、找句、取框。
拉取失败（含离线且无缓存）过 ``RETRY`` 秒再试。

@module koplugin.book.features.reviews.marks
--]]

local Job = require("workers.job")
local Linked = require("features.reviews.linked")
local PageMarks = require("reader.page_marks")
local Perf = require("utils.perf")
local UIManager = require("ui/uimanager")
local logger = require("utils.log")

local RETRY = 60

--- 提供段评的源（WechatSource 实现）。
---@class ParagraphReviewSource
---@field id string
---@field configured fun(self: ParagraphReviewSource): boolean
---@field paragraphReviewsEnabled fun(self: ParagraphReviewSource): boolean
---@field loadTocAsync fun(self: ParagraphReviewSource, identity: BookIdentity, cb: fun(toc: BookChapter[]|nil, err: string|nil)): { cancel: fun() }|nil
---@field refreshTocAsync fun(self: ParagraphReviewSource, identity: BookIdentity, cb: fun(toc: BookChapter[]|nil, err: string|nil)): { cancel: fun() }|nil
---@field isTocCurrent fun(self: ParagraphReviewSource, toc: BookChapter[]|nil): boolean
---@field searchBooksAsync fun(self: ParagraphReviewSource, keyword: string, cb: fun(books: WechatSearchBook[]|nil, err: string|nil)): { cancel: fun() }|nil
---@field paragraphHotspotsAsync fun(self: ParagraphReviewSource, identity: BookIdentity, cb: fun(hotspots: WechatReviewHotspot[]|nil, err: string|nil)): { cancel: fun() }
---@field locateHotspots fun(self: ParagraphReviewSource, hotspots: WechatReviewHotspot[], html: string): WechatReviewSpot[]
---@field paragraphReviewPageAsync fun(self: ParagraphReviewSource, identity: BookIdentity, range: string, max_idx: integer, cb: fun(page: WechatReviewPage|nil, err: string|nil)): { cancel: fun() }

---@class ReviewTarget
---@field key string
---@field fetch fun(cb: fun(data: any, err: string|nil)): { cancel: fun() }
---@field place fun(data: any): ReviewPlacement[]

---@class ReviewMarks: PageMarkLayer
---@field ui table ReaderUI
---@field key string|nil 当前目标键
---@field data any fetch 的结果；nil = 尚未取到
---@field retry_at integer|nil 拉取失败后的重试时刻（秒）
---@field job { cancel: fun() }|nil
---@field current PageMark[] 当前屏上标记（另带 spot）
---@field render_key string|nil
---@field spans integer[][]|nil 章会话 data[i] 的 { 起页, 止页 }
---@field spans_hash integer|nil spans 对应的排版指纹
---@field cache ReviewLinkCache 关联书热点，跨书目复用
local ReviewMarks = {}
ReviewMarks.__index = ReviewMarks

---@param ui table
---@return ReviewMarks
function ReviewMarks.new(ui)
    return setmetatable({ ui = ui, current = {}, cache = Linked.newCache() }, ReviewMarks)
end

---@param self ReviewMarks
local function redraw(self)
    self.render_key = nil
    if self.ui.document then
        UIManager:setDirty(self.ui.dialog, "ui")
    end
end

--- 在子进程里把热点定位到 html：纯 Lua 文本匹配，Kindle 上一章要几百毫秒，放主进程会卡住翻页。
---@param source ParagraphReviewSource
---@param hotspots WechatReviewHotspot[]
---@param html string
---@param cb fun(spots: WechatReviewSpot[]|nil, err: string|nil)
---@return { cancel: fun() }
local function locateAsync(source, hotspots, html, cb)
    local job = Job.run(function() return source:locateHotspots(hotspots, html) end, {
        name = "reviews.locate",
        kind = "light",
        timeout = 60,
        on_done = function(spots) cb(spots) end,
        on_failed = function(err) cb(nil, err) end,
    })
    return { cancel = function() job:cancel() end }
end

--- 微信读书章会话：本章文件即段评定位的 HTML。
---@param self ReviewMarks
---@param identity BookIdentity
---@return ReviewTarget
local function chapterTarget(self, identity)
    local source = identity.source --[[@as ParagraphReviewSource]]
    local fetch = function(cb)
        local locate
        local job = source:paragraphHotspotsAsync(identity, function(hotspots, err)
            if not hotspots then
                cb(nil, err)
                return
            end
            local f = assert(io.open(self.ui.document.file, "rb"))
            local html = f:read("*a")
            f:close()
            locate = locateAsync(source, hotspots, html, cb)
        end)
        return { cancel = function()
            job.cancel()
            if locate then locate.cancel() end
        end }
    end
    -- 屏幕框一句约 1ms（Kindle），整章几十句逐句问太慢：先按页码筛，只问当前屏可能出现的。
    -- 页码随排版（字号、边距、屏幕）变，指纹变了才重算。
    local place = function(spots)
        local document = self.ui.document
        local hash = document:getDocumentRenderingHash()
        if not self.spans or self.spans_hash ~= hash then
            self.spans, self.spans_hash = {}, hash
            for i, spot in ipairs(spots) do
                self.spans[i] = { document:getPageFromXPointer(spot.pos0), document:getPageFromXPointer(spot.pos1) }
            end
        end
        -- 双栏、滚动模式一屏最多跨两页。
        local page = PageMarks.currentPage(self.ui)
        local width, height = PageMarks.screenSize(self.ui)
        local out = {}
        for i, spot in ipairs(spots) do
            local span = self.spans[i]
            if span[1] <= page + 1 and span[2] >= page then
                local boxes = {}
                for _box_idx, box in ipairs(document:getScreenBoxesFromPositions(spot.pos0, spot.pos1, true) or {}) do
                    if PageMarks.intersects(box, width, height) then boxes[#boxes + 1] = box end
                end
                if #boxes > 0 then out[#out + 1] = { entry = { identity = identity, spot = spot }, boxes = boxes } end
            end
        end
        return out
    end
    return {
        key = table.concat({ identity.source_id, identity.stable_id, identity.chapter_idx }, "\0"),
        fetch = fetch,
        place = place,
    }
end

--- 当前位置的段评目标；nil = 不显示。
---@param self ReviewMarks
---@return ReviewTarget|nil
local function currentTarget(self)
    local cur = require("reader.session").current()
    local identity = cur and cur.identity
    if not identity then return nil end
    local source = identity.source --[[@as ParagraphReviewSource|nil]]
    if identity.chapter_idx and source and source.paragraphHotspotsAsync then
        return source:paragraphReviewsEnabled() and chapterTarget(self, identity) or nil
    end
    return Linked.target(self.ui, self.cache, function() redraw(self) end)
end

---@param self ReviewMarks
local function reset(self)
    if self.job then self.job.cancel() end
    Linked.cancel(self.cache)
    self.job, self.key, self.data, self.retry_at, self.spans = nil, nil, nil, nil, nil
    self.current, self.render_key = {}, nil
end

---@param self ReviewMarks
---@param target ReviewTarget
local function fetch(self, target)
    self.key = target.key
    local done = false
    local job = target.fetch(function(data, err)
        done, self.job = true, nil
        if not data then
            logger.warn("book.reviews fetch failed", err)
            self.retry_at = os.time() + RETRY
            return
        end
        self.data = data
        redraw(self)
    end)
    if not done then self.job = job end
end

--- 视口变了就重算屏上标记；目标变了重新拉取，失败的到点再拉。
function ReviewMarks:updateView()
    local target = currentTarget(self)
    if not target then
        reset(self)
        return
    end
    if self.key ~= target.key or (self.retry_at and os.time() >= self.retry_at) then
        reset(self)
        fetch(self, target)
    end
    if not self.data then return end
    local key = PageMarks.viewKey(self.ui, 0)
    if key == self.render_key then return end
    self.render_key = key
    local started_at = Perf.now()
    local marks = {}
    for _idx, placement in ipairs(target.place(self.data)) do
        local entry = placement.entry
        marks[#marks + 1] = {
            spot = entry.spot,
            boxes = placement.boxes,
            tap = function() require("features.reviews.sheet").open(entry.identity, entry.spot) end,
        }
    end
    self.current = marks
    logger.dbg("book.perf reviews.view", Perf.elapsedMs(started_at), "ms marks", #marks)
end

--- 标记图层：刷新视口后交出屏上句子（点按开段评）。
---@return PageMark[]
function ReviewMarks:marks()
    self:updateView()
    return self.current
end

--- 挂到阅读页标记层（priority 20：X-Ray 实体之后占位）。
---@param ui table ReaderUI
function ReviewMarks.install(ui)
    if ui._book_reviews_marks then return end
    local marks = ReviewMarks.new(ui)
    ui._book_reviews_marks = marks
    PageMarks.add(ui, "reviews", 20, marks)
end

return ReviewMarks
