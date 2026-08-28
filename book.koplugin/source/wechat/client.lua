--[[--
微信读书协议客户端：只返回 wire，不做领域转换（仅异步）。

Web 扫码会话（Cookie + X-Vid + X-Skey）只走 ``weread.qq.com/web/*``；
阅读统计等 Agent 能力走 ``i.weread.qq.com/api/agent/gateway``（Skills API Key 由 Web 会话自动获取）。

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

--- 逐页拉取并合并 ``books``，直到凑满 limit 或服务端说没有更多。
---
--- 书城榜单与搜索的翻页规则完全一致（游标取末条 ``searchIdx``，``hasMore`` 判停），
--- 差异只在 URL，所以由 ``fetchPage`` 提供，翻页与合并收口在这里。
---@param limit integer
---@param fetchPage fun(cursor: integer, cb: fun(data: table|nil, err: string|nil)): table|nil
---@param cb fun(wire: table|nil, err: string|nil)
---@return { cancel: fun() }
local function collectPagesAsync(limit, fetchPage, cb)
    local merged, cursor = {}, 0
    local cancelled, job = false, nil

    local function fetchNext()
        if cancelled then
            return
        end
        job = fetchPage(cursor, function(data, err)
            if cancelled then
                return
            end
            if not data then
                cb(nil, err)
                return
            end
            local batch = data.books
            if type(batch) ~= "table" then
                cb({ books = merged, totalCount = data.totalCount, hasMore = data.hasMore })
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
                cb({ books = merged, totalCount = data.totalCount, hasMore = has_more })
                return
            end
            local last = batch[#batch]
            cursor = tonumber(last and last.searchIdx) or (cursor + #batch)
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

--- 单次请求上限：微信读书每页最多 20 条。
---@param count any
---@return integer limit, integer page_size
local function pageBounds(count)
    local limit = math.max(1, math.min(tonumber(count) or 20, 200))
    return limit, math.min(limit, 20)
end

--- 书城分类榜单（无关键词浏览）；自动翻页直到凑满 limit 或无更多。
---@param opts { limit: number|nil, category: string|nil, rank: number|nil }|nil
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Client:storeCatalogAsync(opts, cb)
    opts = opts or {}
    local limit = pageBounds(opts.limit)
    local category = tostring(opts.category or "all")
    if category == "" then
        category = "all"
    end
    local rank = tonumber(opts.rank) or 1
    return collectPagesAsync(limit, function(cursor, on_page)
        return Auth.webApiGetAsync("/web/bookListInCategory/" .. category .. "?" .. Text.formEncode({
            maxIndex = cursor,
            rank = rank,
        }), on_page)
    end, cb)
end

function Client:searchAsync(keyword, count, _scope, cb)
    keyword = tostring(keyword or "")
    if keyword == "" then
        cb({ books = {} })
        return nil
    end
    local limit, page_size = pageBounds(count)
    -- 搜索会话 id：首页返回后带上，后续页才算同一次搜索。
    local sid = ""
    return collectPagesAsync(limit, function(cursor, on_page)
        return Auth.webApiGetAsync("/web/search/global?" .. Text.formEncode({
            keyword = keyword,
            maxIdx = cursor,
            fragmentSize = 120,
            count = page_size,
            sid = sid,
        }), function(data, err)
            if type(data) == "table" and type(data.sid) == "string" and data.sid ~= "" then
                sid = data.sid
            end
            on_page(data, err)
        end)
    end, cb)
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

---@param bookId string
---@param opts { progress: number, chapter_uid: string|number, chapter_idx?: number, chapter_offset?: number, summary?: string }
---@param cb fun(data: table|nil, err: any)
function Client:putProgressAsync(bookId, opts, cb)
    opts = type(opts) == "table" and opts or {}
    bookId = tostring(bookId or "")
    local chapter_uid = opts.chapter_uid and tostring(opts.chapter_uid) or nil
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
        chapter_idx = opts.chapter_idx,
        chapter_offset = opts.chapter_offset,
        summary = opts.summary,
        progress = opts.progress,
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
    local params = { mode = mode or "monthly" }
    if base_time and tonumber(base_time) and tonumber(base_time) > 0 then
        params.baseTime = tonumber(base_time)
    end
    return Auth.agentGatewayAsync("/readdata/detail", params, function(data, err)
        if data then
            cb(data)
        else
            cb(nil, err)
        end
    end)
end

--- 个人划线列表。
---
--- 必须走 Agent 网关：Web 会话打 ``/web/book/bookmarklist`` 恒返回 ``{}``（无 errcode），
--- 而网关 ``/book/bookmarklist`` 返回 ``updated`` + ``chapters``（含 chapterIdx）。
---@param bookId string
---@param cb fun(data: table|nil, err: any)
---@return { cancel: fun() }|nil
function Client:bookmarkListAsync(bookId, cb)
    return Auth.agentGatewayAsync("/book/bookmarklist", {
        bookId = tostring(bookId or ""),
    }, function(data, err)
        if data then
            cb(data)
        else
            cb(nil, err)
        end
    end)
end

--- 本人在该书的想法与点评（含划线想法的 ``range``）。
---@param bookId string
---@param cb fun(data: table|nil, err: any)
---@return { cancel: fun() }|nil
function Client:myReviewsAsync(bookId, cb)
    return Auth.agentGatewayAsync("/review/list/mine", {
        bookid = tostring(bookId or ""),
        count = 100,
        synckey = 0,
    }, function(data, err)
        if data then
            cb(data)
        else
            cb(nil, err)
        end
    end)
end

--- 发表划线下想法（Agent 网关 ``/review/add``）。
---@param body table
---@param cb fun(data: table|nil, err: any)
---@return { cancel: fun() }|nil
function Client:addReviewAsync(body, cb)
    if type(body) ~= "table" then
        cb(nil, _("无效的想法数据"))
        return nil
    end
    return Auth.agentGatewayAsync("/review/add", body, function(data, err)
        if data then
            cb(data)
        else
            cb(nil, err)
        end
    end)
end

--- 修改划线下想法（Agent 网关 ``/review/useredit``）。
---@param body table
---@param cb fun(data: table|nil, err: any)
---@return { cancel: fun() }|nil
function Client:editReviewAsync(body, cb)
    if type(body) ~= "table" then
        cb(nil, _("无效的想法数据"))
        return nil
    end
    return Auth.agentGatewayAsync("/review/useredit", body, function(data, err)
        if data then
            cb(data)
        else
            cb(nil, err)
        end
    end)
end

--- 上传单条划线。
---@param bookId string
---@param chapter_uid string|number
---@param body table
---@param cb fun(data: table|nil, err: any)
---@return { cancel: fun() }|nil
function Client:addBookmarkAsync(bookId, chapter_uid, body, cb)
    bookId = tostring(bookId or "")
    chapter_uid = chapter_uid and tostring(chapter_uid) or nil
    if bookId == "" or not chapter_uid or type(body) ~= "table" then
        cb(nil, _("无效的划线数据"))
        return nil
    end
    local referer = Protocol.readerUrl(bookId, chapter_uid)
    return Auth.webPostAsync("https://weread.qq.com/web/book/addBookmark", JSON.encode(body), {
        headers = { ["Referer"] = referer },
    }, function(raw, err)
        if not raw then
            cb(nil, err)
            return
        end
        local ok, data = pcall(JSON.decode, raw)
        if not ok or type(data) ~= "table" then
            cb(nil, _("划线上传失败"))
            return
        end
        if acceptWebWire(data, err, cb) then
            cb(data)
        end
    end)
end

return Client
