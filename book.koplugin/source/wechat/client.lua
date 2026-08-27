--[[--
微信读书协议客户端：只返回 wire，不做领域转换（仅异步）。

Web 扫码会话（Cookie + X-Vid + X-Skey）只走 ``weread.qq.com/web/*``；
``i.weread.qq.com`` 裸路径需移动端 ``accessToken``，本插件不使用。

@module koplugin.book.source.wechat.client
--]]

local JSON = require("json")
local logger = require("logger")
local Auth = require("source.wechat.auth")
local Context = require("source.wechat.context")
local Protocol = require("source.wechat.protocol")
local Text = require("utils.text")
local _ = require("gettext")

local Client = {}
Client.__index = Client

--- Web API wire：errCode 非 0 视为失败（webApiGetAsync 不自动校验）。
---@param data table|nil
---@param err string|nil
---@param cb fun(data: table|nil, err: string|nil)
---@return boolean
local function acceptWebWire(data, err, cb)
    if not data then
        cb(nil, err)
        return false
    end
    local errcode = tonumber(data.errcode or data.errCode)
    if errcode and errcode ~= 0 then
        cb(nil, data.errmsg or data.errMsg or (_("微信读书错误 ") .. tostring(errcode)))
        return false
    end
    return true
end

--- 构造微信读书客户端实例。
---@param o table|nil
---@return WechatClient
function Client:new(o)
    o = o or {}
    setmetatable(o, self)
    return o
end

--- 是否已登录（有会话）。
---@return boolean
function Client:configured()
    return Auth.hasSession()
end

--- 当前会话请求头（封面下载等复用）。
---@return table
function Client.sessionHeaders()
    return Auth.sessionHeaders()
end

function Client:shelfSyncAsync(cb)
    return Auth.webApiGetAsync("/web/shelf/sync?" .. Text.formEncode({
        synckey = 0,
        teenmode = 0,
    }), function(data, err)
        if acceptWebWire(data, err, cb) then
            cb(data)
        end
    end)
end

--- 查询 bookId 是否已在书架。
---@param bookId string|number
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Client:shelfHasBookAsync(bookId, cb)
    bookId = tostring(bookId or "")
    return Auth.webApiGetAsync("/web/shelf/bookIds?" .. Text.formEncode({
        bookIds = bookId,
    }), cb)
end

--- 加入微信读书书架。
---@param bookId string|number
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Client:addToShelfAsync(bookId, cb)
    bookId = tostring(bookId or "")
    if bookId == "" then
        cb(nil, _("无效书籍"))
        return nil
    end
    return Auth.webApiPostAsync("/web/shelf/add", {
        bookIds = { bookId },
    }, function(data, err)
        if acceptWebWire(data, err, cb) then
            cb(data)
        end
    end)
end

function Client:recentBooksAsync(limit, cb)
    limit = tonumber(limit) or 8
    return Auth.webApiGetAsync("/api/storyfeed/getRecentBooks?count=" .. tostring(limit), cb)
end

--- 书城分类榜单（无关键词浏览）；自动翻页直到凑满 limit 或无更多。
---@param opts { limit: number|nil, category: string|nil, rank: number|nil }|nil
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Client:storeCatalogAsync(opts, cb)
    opts = opts or {}
    local limit = math.max(1, math.min(tonumber(opts.limit) or 20, 200))
    local category = tostring(opts.category or "all")
    if category == "" then
        category = "all"
    end
    local rank = tonumber(opts.rank) or 1
    local max_index = 0
    local merged = {}
    local cancelled = false
    local job

    local function finish(wire, err)
        if cancelled then
            return
        end
        if wire then
            cb(wire)
        else
            cb(nil, err)
        end
    end

    local function fetchNext()
        if cancelled then
            return
        end
        job = Auth.webApiGetAsync("/web/bookListInCategory/" .. category .. "?" .. Text.formEncode({
            maxIndex = max_index,
            rank = rank,
        }), function(data, err)
            if cancelled then
                return
            end
            if not data then
                finish(nil, err)
                return
            end
            local batch = data.books
            if type(batch) ~= "table" then
                finish({ books = merged, totalCount = data.totalCount, hasMore = data.hasMore })
                return
            end
            for _, row in ipairs(batch) do
                merged[#merged + 1] = row
                if #merged >= limit then
                    break
                end
            end
            local has_more = data.hasMore == 1 or data.hasMore == true
            if #merged >= limit or not has_more or #batch == 0 then
                finish({
                    books = merged,
                    totalCount = data.totalCount,
                    hasMore = has_more,
                })
                return
            end
            local last = batch[#batch]
            max_index = tonumber(last and last.searchIdx) or (max_index + #batch)
            fetchNext()
        end)
    end

    fetchNext()
    return {
        cancel = function()
            cancelled = true
            if job and job.cancel then
                job:cancel()
            end
        end,
    }
end

function Client:searchAsync(keyword, count, _scope, cb)
    keyword = tostring(keyword or "")
    if keyword == "" then
        cb({ books = {} })
        return nil
    end
    local limit = math.max(1, math.min(tonumber(count) or 20, 200))
    local page_size = math.min(limit, 20)
    local max_idx = 0
    local sid = ""
    local merged = {}
    local cancelled = false
    local job

    local function finish(wire, err)
        if cancelled then
            return
        end
        if wire then
            cb(wire)
        else
            cb(nil, err)
        end
    end

    local function fetchNext()
        if cancelled then
            return
        end
        job = Auth.webApiGetAsync("/web/search/global?" .. Text.formEncode({
            keyword = keyword,
            maxIdx = max_idx,
            fragmentSize = 120,
            count = page_size,
            sid = sid,
        }), function(data, err)
            if cancelled then
                return
            end
            if not data then
                finish(nil, err)
                return
            end
            if type(data.sid) == "string" and data.sid ~= "" then
                sid = data.sid
            end
            local batch = data.books
            if type(batch) ~= "table" then
                finish({ books = merged, totalCount = data.totalCount, hasMore = data.hasMore })
                return
            end
            for _, row in ipairs(batch) do
                merged[#merged + 1] = row
                if #merged >= limit then
                    break
                end
            end
            local has_more = data.hasMore == 1 or data.hasMore == true
            if #merged >= limit or not has_more or #batch == 0 then
                finish({
                    books = merged,
                    totalCount = data.totalCount,
                    hasMore = has_more,
                })
                return
            end
            local last = batch[#batch]
            max_idx = tonumber(last and last.searchIdx) or (max_idx + #batch)
            fetchNext()
        end)
    end

    fetchNext()
    return {
        cancel = function()
            cancelled = true
            if job and job.cancel then
                job:cancel()
            end
        end,
    }
end

function Client:bookInfoAsync(bookId, cb)
    bookId = tostring(bookId or "")
    return Auth.webApiGetAsync("/web/book/info?" .. Text.formEncode({ bookId = bookId }), function(data, err)
        if acceptWebWire(data, err, cb) then
            cb(data)
        end
    end)
end

function Client:chapterInfosAsync(bookId, cb)
    bookId = tostring(bookId or "")
    return Auth.webApiPostAsync("/web/book/chapterInfos", {
        bookIds = { bookId },
    }, function(data, err)
        if acceptWebWire(data, err, cb) then
            cb(data)
        end
    end)
end

function Client:getProgressAsync(bookId, cb)
    bookId = tostring(bookId or "")
    return Auth.webApiGetAsync("/web/book/getProgress?" .. Text.formEncode({
        bookId = bookId,
        _ = tostring(os.time() * 1000),
    }), function(data, err)
        if acceptWebWire(data, err, cb) then
            cb(data)
        end
    end)
end

function Client:putProgressAsync(bookId, progress_percent, chapter_uid, cb)
    bookId = tostring(bookId or "")
    chapter_uid = chapter_uid and tostring(chapter_uid) or nil
    if bookId == "" or not chapter_uid then
        cb(nil, _("缺少章节信息"))
        return nil
    end
    local psvts = Context.psvts(bookId, chapter_uid)
    if not psvts then
        cb(nil, _("请先打开该章节后再同步进度"))
        return nil
    end
    local referer = Protocol.readerUrl(bookId, chapter_uid)
    local payload = Protocol.makeEnterReadPayload({
        book_id = bookId,
        chapter_uid = chapter_uid,
        progress = progress_percent,
        psvts = psvts,
    })
    return self:reportReadAsync(JSON.encode(payload), referer, function(data, err)
        if data then
            cb({ ok = true })
        else
            logger.warn("weread putProgress", err)
            cb(nil, err or _("进度上传失败"))
        end
    end)
end

function Client:reportReadAsync(body, referer, cb)
    return Auth.webPostAsync("https://weread.qq.com/web/book/read", body, {
        headers = { ["Referer"] = referer or "https://weread.qq.com/" },
    }, function(raw, err)
        if not raw then
            cb(nil, err)
            return
        end
        local ok, data = pcall(JSON.decode, raw)
        if ok and type(data) == "table" then
            cb(data)
        else
            cb({ ok = true })
        end
    end)
end

function Client:readStatsAsync(mode, base_time, cb)
    -- i.weread.qq.com/readdata/detail 仅移动端 accessToken；Web Cookie 无等价接口。
    logger.dbg("weread readStats skipped: no web API", mode or "monthly", base_time)
    cb({})
    return nil
end

function Client:bookmarkListAsync(bookId, cb)
    bookId = tostring(bookId or "")
    return Auth.webApiGetAsync("/web/book/bookmarklist?" .. Text.formEncode({
        bookId = bookId,
        synckey = 0,
    }), function(data, err)
        if acceptWebWire(data, err, cb) then
            cb(data)
        end
    end)
end

function Client:chapterUnderlinesAsync(bookId, chapter_uid, cb)
    return Auth.webApiGetAsync("/web/book/underlines?" .. Text.formEncode({
        bookId = tostring(bookId or ""),
        chapterUid = chapter_uid,
        synckey = 0,
    }), function(data, err)
        if acceptWebWire(data, err, cb) then
            cb(data)
        end
    end)
end

function Client:chapterReviewsAsync(bookId, chapter_uid, batch, cb)
    return Auth.webApiPostAsync("/web/book/readreviews", {
        bookId = tostring(bookId or ""),
        chapterUid = chapter_uid,
        reviews = batch,
    }, function(data, err)
        if not data then
            cb(nil, err)
            return
        end
        if acceptWebWire(data, err, cb) then
            cb(data)
        end
    end)
end

return Client
