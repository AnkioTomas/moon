--[[--
微信读书协议客户端：只返回 wire，不做领域转换（仅异步）。

Web 扫码会话（Cookie + X-Vid + X-Skey）只走 ``weread.qq.com/web/*``；
阅读统计等 Agent 能力走 ``i.weread.qq.com/api/agent/gateway``（Skills API Key 由 Web 会话自动获取）。

@module koplugin.book.source.wechat.client
--]]

local JSON = require("json")
local logger = require("utils.log")
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

--- 全量拉取书架（synckey=0 表示不做增量）。
---@param cb fun(data: table|nil, err: string|nil) 原始 wire 数据
---@return { cancel: fun() }|nil
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

    --- 取下一页并并入 merged；凑满 limit、服务端说没有更多或本页为空即收尾。
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

--- 全站搜索；自动翻页直到凑满 count 或无更多。关键词为空直接回空结果。
--- 首页回包里的 sid 会带到后续页，服务端据此认定是同一次搜索。
---@param keyword string|nil 搜索关键词
---@param count number|nil 结果条数上限，缺省 20，最多 200
---@param _scope any 保留参数，当前实现不使用
---@param cb fun(wire: table|nil, err: string|nil) 合并后的 { books, totalCount, hasMore }
---@return { cancel: fun() }|nil
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

--- 拉取书籍详情（含书籍版本号）。
---@param bookId string|number|nil 微信读书 bookId，即 stable_id
---@param cb fun(data: table|nil, err: string|nil) 原始 wire 数据
---@return { cancel: fun() }|nil
function Client:bookInfoAsync(bookId, cb)
    bookId = tostring(bookId or "")
    return Auth.webApiGetAsync("/web/book/info?" .. Text.formEncode({ bookId = bookId }), function(data, err)
        if acceptWebWire(data, err, cb) then
            cb(data)
        end
    end)
end

--- 拉取整本书的章节目录。
---@param bookId string|number|nil 微信读书 bookId，即 stable_id
---@param cb fun(data: table|nil, err: string|nil) 原始 wire 数据
---@return { cancel: fun() }|nil
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

--- 拉取云端阅读进度；带毫秒时间戳参数避开中间层缓存。
---@param bookId string|number|nil 微信读书 bookId，即 stable_id
---@param cb fun(data: table|nil, err: string|nil) 原始 wire 数据
---@return { cancel: fun() }|nil
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

--- 上报阅读行为（进度与时长共用的 /web/book/read 接口）。
--- 回包不是 JSON 一律按失败：登录页 HTML 与 WAF 拦截页都长这样，当成功会静默丢数据。
---@param body string 已编码好的 JSON 请求体
---@param referer string|nil Referer 头，缺省用站点首页
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Client:reportReadAsync(body, referer, cb)
    return Auth.webPostAsync("https://weread.qq.com/web/book/read", body, {
        headers = { ["Referer"] = referer or "https://weread.qq.com/" },
    }, function(raw, err)
        if not raw then
            cb(nil, err)
            return
        end
        local ok, data = pcall(JSON.decode, raw)
        if not ok or type(data) ~= "table" then
            -- 登录页 HTML、WAF 拦截页、空响应都会走到这里。当成功上报的话，
            -- 调用方会把这条进度/时长标记为已同步，数据静默丢失。
            logger.warn("weread report read: unexpected response", tostring(raw):sub(1, 120))
            cb(nil, _("上报响应异常"))
            return
        end
        -- errcode 非 0（会话失效、参数被拒）也是失败：不校验的话调用方会把这条
        -- 进度/时长标记为已同步，数据静默丢失。
        if not acceptWebWire(data, nil, cb) then
            logger.warn("weread report read rejected",
                tostring(data.errcode or data.errCode), tostring(data.errmsg or data.errMsg))
            return
        end
        cb(data)
    end)
end

--- 经 Agent 网关拉取阅读统计明细。
---@param mode string|nil 统计口径，缺省 "monthly"
---@param base_time number|nil 基准时间戳（秒），大于 0 才带上
---@param cb fun(data: table|nil, err: string|nil) 原始 wire 数据
---@return { cancel: fun() }|nil
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
