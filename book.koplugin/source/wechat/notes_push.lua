--[[--
微信读书单章注解上行：删除 → 预检 → 取坐标 → 提交划线 → 回查确认 → 同步样式 → 推想法。

全程串行，任何一步失败整轮失败（已成功的远端 id 已回填到注解上，下轮 preflight 认回）。
注解条目就地改写（wr_* 字段、删除墓碑出列），由调用方落库。

@module koplugin.book.source.wechat.notes_push
--]]

local logger = require("utils.log")
local Notes = require("source.wechat.notes")
local Annotations = require("book.annotations")
local Toc = require("source.wechat.toc")
local WChapter = require("source.wechat.chapter")
local Context = require("source.wechat.context")
local Mapper = require("source.wechat.mapper")
local _ = require("gettext")

---@class WechatNotesPush
---@field client WechatClient
---@field identity BookIdentity
---@field book_id string
---@field chapter_idx integer
---@field chapter_uid string
---@field local_html string|nil
---@field annotations table[]
---@field confirmed table<table, boolean> 已在远端确认的条目
---@field preflight_wire table|nil
---@field job { cancel: fun() }|nil 在途请求
---@field cancelled boolean
---@field finished boolean
---@field cb fun(ok: boolean|nil, err: string|nil)
local Push = {}
Push.__index = Push

local NotesPush = {}

---@param ok boolean|nil
---@param err string|nil
function Push:finish(ok, err)
    if self.cancelled or self.finished then return end
    self.finished = true
    self.cb(ok, err)
end

---@param seen table<table, boolean>
function Push:confirm(seen)
    for item in pairs(seen) do self.confirmed[item] = true end
end

--- 发一个请求：失败整轮失败，成功把回包交给 ok。
---@param start fun(done: fun(wire: table|nil, err: string|nil)): { cancel: fun() }|nil
---@param fail_msg string|nil 回包没给错误时的提示
---@param ok fun(wire: table)
function Push:call(start, fail_msg, ok)
    self.seq = (self.seq or 0) + 1
    local seq = self.seq
    local handle = start(function(wire, err)
        self.job = nil
        if self.cancelled then return end
        if not wire then
            self:finish(nil, err or fail_msg)
            return
        end
        ok(wire)
    end)
    -- 回调同步触发时已发出下一个请求，不能用旧句柄覆盖它（同 http/mirror）。
    if self.seq == seq then self.job = handle end
end

--- 逐个串行处理：step 完成后调 next 进下一个，全部完成调 done；step 失败不调 next 即中止。
---@param items table[]
---@param step fun(item: table, next: fun())
---@param done fun()
function Push:each(items, step, done)
    local index = 0
    local function nextItem()
        if self.cancelled then return end
        index = index + 1
        local item = items[index]
        if not item then
            done()
            return
        end
        step(item, nextItem)
    end
    nextItem()
end

--- 删除墓碑推完即出列。
---@param item table
function Push:forget(item)
    if not item.wr_deleted then return end
    for i = #self.annotations, 1, -1 do
        if self.annotations[i] == item then
            table.remove(self.annotations, i)
            return
        end
    end
end

--- 先提交本地删除（想法先于划线），再预检。
function Push:deletes()
    local client = self.client
    self:each(Notes.deleteCandidates(self.annotations), function(item, next)
        local function removeBookmark()
            self:call(function(done)
                return client:removeBookmarkAsync(item.wr_bookmark_id, done)
            end, _("划线上传失败"), function()
                item.wr_bookmark_id = nil
                self:forget(item)
                next()
            end)
        end
        local function dropBookmark()
            if not item.wr_deleted then
                self:forget(item)
                next()
            elseif item.wr_bookmark_id then
                removeBookmark()
            elseif item.wr_range then
                -- 只有想法的条目没记过划线 id；远端划线与想法同 range，删想法不会连带删它。
                self:call(function(done)
                    return client:bookmarkListAsync(self.book_id, done)
                end, _("无法预检远端划线"), function(wire)
                    item.wr_bookmark_id = Notes.bookmarkIdByRange(wire, self.chapter_uid, item.wr_range)
                    if item.wr_bookmark_id then
                        removeBookmark()
                    else
                        self:forget(item)
                        next()
                    end
                end)
            else
                self:forget(item)
                next()
            end
        end
        if not item.wr_review_id then
            item.wr_delete_review = nil
            dropBookmark()
            return
        end
        self:call(function(done)
            return client:deleteReviewAsync(item.wr_review_id, done)
        end, _("想法上传失败"), function()
            item.wr_review_id, item.wr_delete_review = nil, nil
            dropBookmark()
        end)
    end, function() self:preflight() end)
end

--- 拉远端划线与想法：清掉远端已不存在的 id，认回上轮已成功但本地未确认的条目。
function Push:preflight()
    self:call(function(done)
        return self.client:bookmarkListAsync(self.book_id, done)
    end, _("无法预检远端划线"), function(wire)
        self.preflight_wire = wire
        local bookmark_ids = Notes.bookmarkIds(wire, self.chapter_uid)
        for _idx, item in ipairs(self.annotations) do
            if not item.wr_deleted and item.wr_bookmark_id
                    and not bookmark_ids[tostring(item.wr_bookmark_id)] then
                item.wr_bookmark_id = nil
            end
        end
        self:confirm(Notes.reconcileBookmarks(self.annotations, wire, self.chapter_uid))
        -- 想法列表被服务端拒绝（如 -2003）不能拖死划线上传：按「只拿到一页」处理，保留已有 id。
        local job = self.client:myReviewsAsync(self.book_id, function(reviews)
            self.job = nil
            if self.cancelled then return end
            if type(reviews) ~= "table" then
                -- 没有远端想法清单就认不回上轮已成功的想法，新想法此轮不推（否则重复）。
                self.reviews_unknown = true
                reviews = { reviews = {}, hasMore = 1 }
            end
            -- 只拿到一页时保留 id：误清会让 addReviewAsync 在云端重建重复想法。
            if Notes.reviewsComplete(reviews) then
                local review_ids = Notes.reviewIds(reviews)
                for _idx, item in ipairs(self.annotations) do
                    if not item.wr_deleted and item.wr_review_id
                            and not review_ids[tostring(item.wr_review_id)] then
                        item.wr_review_id = nil
                    end
                end
            end
            Notes.reconcileReviews(self.annotations, reviews)
            -- 远端 id 被清掉的想法要重新标 wr_review_only，否则既不定位也不推送。
            Notes.preparePush(self.annotations)
            self:locate()
        end)
        if self.job == nil and not self.cancelled then self.job = job end
    end)
end

--- 需要坐标的条目取一次当前章节 range 原文，所有 wr_range 在首个写请求前算完。
function Push:locate()
    local range_items = Notes.rangeItems(self.annotations, self.confirmed)
    if #range_items == 0 then
        self:updates()
        return
    end
    if not self.local_html then
        self:finish(nil, _("缺少本地章节正文，无法定位划线"))
        return
    end
    local toc = Toc.read(self.identity.source_id, self.identity.stable_id)
    local chapter = toc and toc[self.chapter_idx]
    if not chapter then
        self:finish(nil, _("缺少章节信息"))
        return
    end
    self.job = WChapter.fetchHtmlAsync(self.book_id, chapter, function(_html, err, range_source, format)
        self.job = nil
        if self.cancelled then return end
        if not range_source then
            self:finish(nil, err or _("无法获取章节坐标"))
            return
        end
        local wire = Annotations.rangeMapping(range_source, format)
        local flow = Annotations.flow(self.local_html)
        -- 定位不了的条目只跳过它自己：失败不落库，整章中止会让同一条每轮都卡住其余划线。
        for _idx, item in ipairs(range_items) do
            local range, range_err = Annotations.toWireRange(wire, flow, item.text, item.pos0, item.pos1)
            if range then
                item.wr_range = range
            else
                logger.warn("wechat highlight range skipped", self.book_id, self.chapter_idx, range_err)
            end
        end
        self:confirm(Notes.reconcileBookmarks(self.annotations, self.preflight_wire, self.chapter_uid))
        local candidates = {}
        for _idx, item in ipairs(Notes.pushCandidates(self.annotations)) do
            if item.wr_range then candidates[#candidates + 1] = item end
        end
        if #candidates == 0 then
            self:updates()
            return
        end
        -- 服务端若在正文中加入标记，后面的区间先提交不会推移前面的坐标。
        -- 正确性仍由 postflight 确认，不依赖这个顺序。
        table.sort(candidates, function(a, b)
            return (tonumber(a.wr_range:match("^(%d+)")) or 0) > (tonumber(b.wr_range:match("^(%d+)")) or 0)
        end)
        self:withBookVersion(candidates)
    end)
end

--- addBookmark 必须带书籍版本号；进程内没有就拉一次详情。
---@param candidates table[]
function Push:withBookVersion(candidates)
    local version = Context.bookVersion(self.book_id)
    if version then
        self:bookmarks(version, candidates)
        return
    end
    self:call(function(done)
        return self.client:bookInfoAsync(self.book_id, done)
    end, nil, function(wire)
        version = Mapper.bookVersion(wire)
        if not version then
            self:finish(nil, _("缺少书籍版本"))
            return
        end
        Context.rememberBookVersion(self.book_id, version)
        self:bookmarks(version, candidates)
    end)
end

--- 串行提交新划线，提交完回查一次确认 canonical id/range。
---@param version number
---@param candidates table[]
function Push:bookmarks(version, candidates)
    local source_idx = Toc.sourceIndex(self.identity.source_id, self.identity.stable_id, self.chapter_idx)
        or self.chapter_idx
    local submitted = {}
    self:each(candidates, function(item, next)
        local body, body_err = Notes.toBookmarkBody(self.book_id, self.chapter_uid, source_idx, version, item)
        if not body then
            self:finish(nil, body_err)
            return
        end
        self:call(function(done)
            return self.client:addBookmarkAsync(self.book_id, self.chapter_uid, body, done)
        end, _("划线上传失败"), function(wire)
            item.wr_range = body.range
            item.wr_bookmark_id = wire.bookmarkId or wire.id
            submitted[#submitted + 1] = item
            next()
        end)
    end, function() self:postflight(submitted) end)
end

---@param submitted table[]
function Push:postflight(submitted)
    self:call(function(done)
        return self.client:bookmarkListAsync(self.book_id, done)
    end, _("无法确认划线上传结果"), function(wire)
        self:confirm(Notes.reconcileBookmarks(self.annotations, wire, self.chapter_uid))
        for _idx, item in ipairs(submitted) do
            if not item.wr_bookmark_id or not self.confirmed[item] then
                self:finish(nil, _("划线上传后未在远端确认"))
                return
            end
        end
        self:updates()
    end)
end

--- 已确认的远端划线同步样式和颜色。
function Push:updates()
    local items = {}
    for _idx, item in ipairs(Notes.bookmarkUpdateCandidates(self.annotations)) do
        if self.confirmed[item] then items[#items + 1] = item end
    end
    self:each(items, function(item, next)
        self:call(function(done)
            return self.client:updateBookmarkAsync(Notes.toBookmarkUpdateBody(item), done)
        end, _("划线上传失败"), function()
            item.wr_update_bookmark = nil
            next()
        end)
    end, function() self:reviews() end)
end

--- 串行推想法：已有 reviewId 走 edit，否则 add。
function Push:reviews()
    local deferred = false
    self:each(Notes.notePushCandidates(self.annotations), function(item, next)
        if not item.wr_review_id and self.reviews_unknown then
            deferred = true
            next()
            return
        end
        if not item.wr_review_id and not self.confirmed[item] and not item.wr_review_only then
            self:finish(nil, _("远端划线未确认，不能上传想法"))
            return
        end
        if item.wr_review_id then
            local body, body_err = Notes.toReviewEditBody(self.book_id, self.chapter_uid, item)
            if not body then
                self:finish(nil, body_err)
                return
            end
            self:call(function(done)
                return self.client:editReviewAsync(body, done)
            end, _("想法上传失败"), function()
                item.wr_update_review = nil
                next()
            end)
            return
        end
        local body, body_err = Notes.toReviewBody(self.book_id, self.chapter_uid, item)
        if not body then
            self:finish(nil, body_err)
            return
        end
        self:call(function(done)
            return self.client:addReviewAsync(body, done)
        end, _("想法上传失败"), function(wire)
            local review_id = wire.reviewId or (type(wire.data) == "table" and wire.data.reviewId)
            if not review_id then
                self:finish(nil, _("想法上传成功但缺少 reviewId"))
                return
            end
            item.wr_review_id = review_id
            next()
        end)
    end, function()
        if deferred then
            self:finish(nil, _("想法列表暂不可用，稍后重试"))
        else
            self:finish(true)
        end
    end)
end

--- 推送一章注解。
---@param client WechatClient
---@param identity BookIdentity 章会话身份（chapter_idx 必填）
---@param chapter_uid string
---@param local_html string|nil 本地章节正文；有新划线 / 新想法要定位时必需
---@param annotations table[] 就地改写
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }
function NotesPush.run(client, identity, chapter_uid, local_html, annotations, cb)
    local self = setmetatable({
        client = client,
        identity = identity,
        book_id = identity.stable_id,
        chapter_idx = tonumber(identity.chapter_idx),
        chapter_uid = chapter_uid,
        local_html = local_html,
        annotations = annotations,
        confirmed = {},
        cancelled = false,
        finished = false,
        cb = cb,
    }, Push)
    self:deletes()
    return { cancel = function()
            self.cancelled = true
            if self.job then self.job:cancel() end
        end }
end

return NotesPush
