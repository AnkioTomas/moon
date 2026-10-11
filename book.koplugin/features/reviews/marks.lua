--[[--
页内段评标记：本章他人段评的句子画虚线下划线，点按弹出段评列表。

只认会话属主源提供的 ``paragraphReviewsEnabled`` / ``paragraphReviewsAsync`` / ``paragraphReviewPageAsync``
（目前只有微信读书），只在章节会话里生效。热点每章拉一次（未联网时不拉，下次绘制再试）；
翻页只用已定位的 xpointer 取屏幕框，不做文本搜索。

@module koplugin.book.features.reviews.marks
--]]

local PageMarks = require("reader.page_marks")
local UIManager = require("ui/uimanager")
local logger = require("utils.log")

--- 提供段评的源（WechatSource 实现）。
---@class ParagraphReviewSource
---@field paragraphReviewsEnabled fun(self: ParagraphReviewSource): boolean
---@field paragraphReviewsAsync fun(self: ParagraphReviewSource, identity: BookIdentity, html_path: string, cb: fun(spots: WechatReviewSpot[]|nil, err: string|nil)): { cancel: fun() }
---@field paragraphReviewPageAsync fun(self: ParagraphReviewSource, identity: BookIdentity, range: string, max_idx: integer, cb: fun(page: WechatReviewPage|nil, err: string|nil)): { cancel: fun() }

---@class ReviewMarks: PageMarkLayer
---@field ui table ReaderUI
---@field chapter string|nil 当前热点所属章节键
---@field spots WechatReviewSpot[]|nil nil = 尚未取到
---@field job { cancel: fun() }|nil
---@field current PageMark[] 当前屏上标记（另带 spot）
---@field render_key string|nil
local ReviewMarks = {}
ReviewMarks.__index = ReviewMarks

---@param ui table
---@return ReviewMarks
function ReviewMarks.new(ui)
    return setmetatable({ ui = ui, current = {} }, ReviewMarks)
end

--- 当前会话可显示段评时返回身份。
---@return BookIdentity|nil
local function eligibleIdentity()
    local cur = require("reader.session").current()
    local identity = cur and cur.identity
    local source = identity and identity.source --[[@as ParagraphReviewSource|nil]]
    if not (identity and identity.chapter_idx and source and source.paragraphReviewsAsync) then
        return nil
    end
    return source:paragraphReviewsEnabled() and identity or nil
end

---@param self ReviewMarks
local function reset(self)
    if self.job then self.job.cancel() end
    self.job, self.chapter, self.spots = nil, nil, nil
    self.current, self.render_key = {}, nil
end

---@param self ReviewMarks
---@param identity BookIdentity
---@param chapter string
local function fetch(self, identity, chapter)
    if not require("ui/network/manager"):isConnected() then
        return
    end
    self.chapter = chapter
    local source = identity.source --[[@as ParagraphReviewSource]]
    self.job = source:paragraphReviewsAsync(identity, self.ui.document.file, function(spots, err)
        self.job = nil
        if not spots then
            logger.warn("book.reviews fetch failed", err)
            spots = {}
        end
        self.spots = spots
        if self.ui.document then
            UIManager:setDirty(self.ui.dialog, "ui")
        end
    end)
end

--- 视口变了就重算屏上标记；热点未就绪时按需拉取。
function ReviewMarks:updateView()
    local identity = eligibleIdentity()
    if not identity then
        reset(self)
        return
    end
    local chapter = table.concat({ identity.source_id, identity.stable_id, identity.chapter_idx }, "\0")
    if self.chapter ~= chapter then
        reset(self)
        fetch(self, identity, chapter)
        return
    end
    if not self.spots then return end
    local key = PageMarks.viewKey(self.ui, #self.spots)
    if key == self.render_key then return end
    self.render_key = key
    local document = self.ui.document
    local width, height = PageMarks.screenSize(self.ui)
    local marks = {}
    for _idx, spot in ipairs(self.spots) do
        local boxes = {}
        for _box_idx, box in ipairs(document:getScreenBoxesFromPositions(spot.pos0, spot.pos1, true) or {}) do
            if PageMarks.intersects(box, width, height) then boxes[#boxes + 1] = box end
        end
        if #boxes > 0 then
            marks[#marks + 1] = {
                spot = spot,
                boxes = boxes,
                tap = function() require("features.reviews.sheet").open(identity, spot) end,
            }
        end
    end
    self.current = marks
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
