--[[--
微信读书协议客户端：只返回 wire，不做领域转换（仅异步）。

会话（Cookie + X-Vid + X-Skey）用于网页接口；Web 读不到的划线、想法、阅读统计
走 Eink ``i.weread.qq.com``；写想法 / 划线走 ``weread.qq.com/web/*``。

@module koplugin.book.source.wechat.client
--]]

local JSON = require("json")
local logger = require("utils.log")
local Auth = require("source.wechat.auth")
local Eink = require("source.wechat.eink")
local Context = require("source.wechat.context")
local Protocol = require("source.wechat.protocol")
local Text = require("utils.text")
local _ = require("gettext")

local WEB = "https://weread.qq.com"
-- 本人想法每页条数与翻页上限（hasMore=1 时按回包 maxIdx 续拉）
local MY_REVIEWS_PAGE = 100
local MY_REVIEWS_MAX_PAGES = 20

--- 无状态：方法保留冒号形式，模块表本身就是 ``source.shelf`` 要的远端。
---@class WechatClient
local Client = {}

--- 回包解码并校验 errcode。
--- 不是 JSON 一律按失败：登录页 HTML 与 WAF 拦截页都长这样，当成功会静默丢数据。
---@param url string 仅用于日志
---@param cb fun(data: table|nil, err: string|nil)
---@return fun(raw: string|nil, err: string|nil)
local function webWire(url, cb)
    return function(raw, err)
        if not raw then
            cb(nil, err)
            return
        end
        local ok, data = pcall(require("utils.json").decode, raw)
        if not ok or type(data) ~= "table" then
            logger.warn("weread web: unexpected response", url, raw:sub(1, 120))
            cb(nil, _("返回非 JSON"))
            return
        end
        local errcode = tonumber(data.errcode or data.errCode)
        if errcode and errcode ~= 0 then
            cb(nil, data.errmsg or data.errMsg or (_("微信读书错误 ") .. tostring(errcode)))
            return
        end
        cb(data)
    end
end

---@param path string 以 /web 开头
---@param query table
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function getWebAsync(path, query, cb)
    local url = WEB .. path .. "?" .. Text.formEncode(query)
    return Auth.webGetAsync(url, nil, webWire(url, cb))
end

---@param path string 以 /web 开头
---@param body table 请求体，以 JSON 发出
---@param referer string|nil 缺省用站点首页
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function postWebAsync(path, body, referer, cb)
    local url = WEB .. path
    return Auth.webPostAsync(url, JSON.encode(body), referer and { headers = { Referer = referer } } or nil,
        webWire(url, cb))
end

--- 书城搜索：``books[]`` 每条 ``{ type, bookInfo = { bookId, title, author, publisher, … } }``。
---@param keyword string
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Client:searchAsync(keyword, cb)
    return getWebAsync("/web/search/global", { keyword = keyword, maxIdx = 0, fragmentSize = 120, count = 20 }, cb)
end

--- 全量拉取书架（synckey=0 表示不做增量）。
---@param cb fun(data: table|nil, err: string|nil) 原始 wire 数据
---@return { cancel: fun() }|nil
function Client:shelfSyncAsync(cb)
    return getWebAsync("/web/shelf/sync", { synckey = 0, teenmode = 0 }, cb)
end

--- 加入微信读书书架。
---@param bookId string
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Client:addToShelfAsync(bookId, cb)
    return postWebAsync("/web/shelf/add", { bookIds = { bookId } }, nil, cb)
end

--- 从微信读书书架删除（移动端接口，带网页会话）。
---@param bookId string
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Client:removeFromShelfAsync(bookId, cb)
    local url = "https://i.weread.qq.com/shelf/delete"
    return Auth.webPostAsync(url, JSON.encode({ bookIds = { bookId }, albumIds = {}, archiveIds = {} }), nil,
        webWire(url, cb))
end

--- 拉取书籍详情（含书籍版本号）。
---@param bookId string 微信读书 bookId，即 stable_id
---@param cb fun(data: table|nil, err: string|nil) 原始 wire 数据
---@return { cancel: fun() }|nil
function Client:bookInfoAsync(bookId, cb)
    return getWebAsync("/web/book/info", { bookId = bookId }, cb)
end

--- 拉取整本书的章节目录。
---@param bookId string 微信读书 bookId，即 stable_id
---@param cb fun(data: table|nil, err: string|nil) 原始 wire 数据
---@return { cancel: fun() }|nil
function Client:chapterInfosAsync(bookId, cb)
    return postWebAsync("/web/book/chapterInfos", { bookIds = { bookId } }, nil, cb)
end

--- 拉取云端阅读进度；带毫秒时间戳参数避开中间层缓存。
---@param bookId string 微信读书 bookId，即 stable_id
---@param cb fun(data: table|nil, err: string|nil) 原始 wire 数据
---@return { cancel: fun() }|nil
function Client:getProgressAsync(bookId, cb)
    return getWebAsync("/web/book/getProgress", { bookId = bookId, _ = tostring(os.time() * 1000) }, cb)
end

---@param bookId string
---@param opts { progress: number, chapter_uid: string|number, chapter_idx?: number, chapter_offset?: number, summary?: string }
---@param cb fun(data: table|nil, err: any)
function Client:putProgressAsync(bookId, opts, cb)
    local chapter_uid = tostring(opts.chapter_uid)
    local cancelled, job = false, nil
    -- 与时长心跳共用真实阅读页会话：伪造的 ps / pc 服务端收下 rt 却不记进度。
    job = Context.sessionAsync(self, bookId, false, function(session, session_err)
        if cancelled then return end
        if not session then
            logger.warn("weread putProgress session", bookId, session_err)
            cb(nil, session_err)
            return
        end
        local payload = Protocol.makeEnterReadPayload({
            book_id = bookId,
            chapter_uid = chapter_uid,
            chapter_idx = opts.chapter_idx,
            chapter_offset = opts.chapter_offset,
            summary = opts.summary,
            progress = opts.progress,
            psvts = session.psvts,
            pclts = session.pclts,
        })
        job = self:reportReadAsync(payload, Protocol.readerUrl(bookId, chapter_uid), function(data, err)
            if cancelled then return end
            if data then
                session.entered = true
                cb({ ok = true })
            else
                logger.warn("weread putProgress", err)
                cb(nil, err)
            end
        end)
    end)
    return { cancel = function()
            cancelled = true
            if job then job.cancel() end
        end }
end

--- 打开网页阅读页，取时长上报会话参数 psvts / pclts / token（weread.koplugin 同款正则）。
---@param bookId string
---@param cb fun(state: { psvts: string, pclts: string|nil, token: string|nil }|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Client:readerStateAsync(bookId, cb)
    local url = Protocol.readerUrl(bookId)
    return Auth.webGetAsync(url, { headers = { Referer = url } }, function(raw, err)
        if not raw then
            cb(nil, err)
            return
        end
        local psvts = raw:match([["psvts"%s*:%s*"([^"]+)"]])
        if not psvts then
            logger.warn("weread reader page without psvts", raw:sub(1, 120))
            cb(nil, "reader.psvts not found")
            return
        end
        cb({
            psvts = psvts,
            pclts = raw:match([["pclts"%s*:%s*"([^"]+)"]]),
            token = raw:match([["token"%s*:%s*"([^"]+)"]]),
        })
    end)
end

--- 上报阅读行为（进度与时长共用的 /web/book/read 接口）。
---@param body table 已签名的请求体
---@param referer string|nil Referer 头，缺省用站点首页
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Client:reportReadAsync(body, referer, cb)
    return postWebAsync("/web/book/read", body, referer, function(data, err)
        if not data then
            cb(nil, err)
            return
        end
        -- 服务端受理的回包带 succ=1 或 synckey；两者都没有是「收下但没记账」，
        -- 当成功的话调用方会把这条进度/时长标记为已同步，数据静默丢失。
        if not (data.succ == true or tonumber(data.succ) == 1 or data.synckey ~= nil) then
            logger.warn("weread report read not accepted")
            cb(nil, _("上报响应异常"))
            return
        end
        cb(data)
    end)
end

--- 拉取阅读统计明细（Eink ``/readdata/detail``）。
---@param mode string|nil 统计口径，缺省 "monthly"
---@param base_time number|nil 基准时间戳（秒），大于 0 才带上
---@param cb fun(data: table|nil, err: string|nil) 原始 wire 数据
---@return { cancel: fun() }|nil
function Client:readStatsAsync(mode, base_time, cb)
    local query = { mode = mode or "monthly" }
    if base_time and base_time > 0 then
        query.baseTime = base_time
    end
    return Eink.callAsync("GET", "/readdata/detail", { query = query }, cb)
end

--- 单书阅读详情（Eink ``/book/readinfo``，``readDetail.data`` 为按日 ``{ readDate, readTime }``）。
---
--- 不能走 Web：``/web/book/readinfo`` 对部分书恒回 ``showDetail=0``、不给按日明细。
---@param bookId string
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Client:readInfoAsync(bookId, cb)
    return Eink.callAsync("GET", "/book/readinfo", {
        query = { bookId = bookId, readingDetail = 1 },
    }, cb)
end

--- 个人划线列表（Eink ``/book/bookmarklist``，回 ``updated`` + ``chapters``）。
---
--- 不能走 Web：Web 会话打 ``/web/book/bookmarklist`` 恒返回 ``{}``（无 errcode）。
---@param bookId string
---@param cb fun(data: table|nil, err: any)
---@return { cancel: fun() }|nil
function Client:bookmarkListAsync(bookId, cb)
    return Eink.callAsync("GET", "/book/bookmarklist", {
        query = { bookId = bookId, synckey = 0 },
    }, cb)
end

--- 本人在该书的想法与点评（含划线想法的 ``range``）。
---
--- Eink ``/review/list`` 会混入别的书的想法（实测按 range 挂进当前书造成串书），
--- 回包里 ``bookId`` 不是这本书的条目剔掉；totalCount 保持原值，全量判定仍按服务端口径。
--- ``hasMore=1`` 时带回包 ``maxIdx`` 续拉并按 reviewId 去重；中途失败交回已拿到的部分（hasMore 仍为 1）。
---@param bookId string
---@param cb fun(data: table|nil, err: any)
---@return { cancel: fun() }|nil
function Client:myReviewsAsync(bookId, cb)
    local own, seen, first, job = {}, {}, nil, nil
    local cancelled = false
    local function fetch(max_idx, pages)
        job = Eink.callAsync("GET", "/review/list", {
            query = {
                bookId = bookId,
                listType = 1,
                listMode = 0,
                mine = 1,
                synckey = 0,
                count = MY_REVIEWS_PAGE,
                maxIdx = max_idx,
            },
        }, function(data, err)
            if cancelled then return end
            if type(data) ~= "table" or type(data.reviews) ~= "table" then
                -- 翻页失败时交回已拿到的部分，hasMore 保持 1，全量判定不会误判
                if first then cb(first) else cb(data, err) end
                return
            end
            first = first or data
            local added = 0
            for _idx, entry in ipairs(data.reviews) do
                local review = type(entry) == "table" and (entry.review or entry) or nil
                local owner = type(review) == "table" and review.bookId
                local id = type(review) == "table" and (review.reviewId or entry.reviewId)
                if (owner == nil or tostring(owner) == bookId) and not (id and seen[id]) then
                    if id then seen[id] = true end
                    own[#own + 1] = entry
                end
                added = added + 1
            end
            first.reviews, first.hasMore = own, data.hasMore
            local next_idx = tonumber(data.maxIdx)
            if tonumber(data.hasMore) == 1 and added > 0 and next_idx and next_idx ~= max_idx
                    and pages < MY_REVIEWS_MAX_PAGES then
                fetch(next_idx, pages + 1)
                return
            end
            cb(first)
        end)
    end
    fetch(0, 1)
    return { cancel = function()
            cancelled = true
            if job then job.cancel() end
        end }
end

--- 发表划线下想法。
---@param body table
---@param cb fun(data: table|nil, err: any)
---@return { cancel: fun() }|nil
function Client:addReviewAsync(body, cb)
    return postWebAsync("/web/review/add", body, nil, cb)
end

--- 修改划线下想法。
---@param body table
---@param cb fun(data: table|nil, err: any)
---@return { cancel: fun() }|nil
function Client:editReviewAsync(body, cb)
    return postWebAsync("/web/review/edit", body, nil, cb)
end

--- 删除想法。
---@param review_id string|number
---@param cb fun(data: table|nil, err: any)
---@return { cancel: fun() }|nil
function Client:deleteReviewAsync(review_id, cb)
    return postWebAsync("/web/review/delete", { reviewId = tostring(review_id) }, nil, cb)
end

--- 更新划线样式和颜色。
---@param body table
---@param cb fun(data: table|nil, err: any)
---@return { cancel: fun() }|nil
function Client:updateBookmarkAsync(body, cb)
    return postWebAsync("/web/book/updateBookmark", body, nil, cb)
end

--- 删除划线。
---@param bookmark_id string|number
---@param cb fun(data: table|nil, err: any)
---@return { cancel: fun() }|nil
function Client:removeBookmarkAsync(bookmark_id, cb)
    return postWebAsync("/web/book/removeBookmark", { bookmarkId = tostring(bookmark_id) }, nil, cb)
end

--- 上传单条划线。
---@param bookId string
---@param chapter_uid string|number
---@param body table
---@param cb fun(data: table|nil, err: any)
---@return { cancel: fun() }|nil
function Client:addBookmarkAsync(bookId, chapter_uid, body, cb)
    return postWebAsync("/web/book/addBookmark", body, Protocol.readerUrl(bookId, chapter_uid), cb)
end

--- 本章热门划线与段评锚点：``underlines[]`` 每条 ``{ range, count, type }``（type 0 = 只有段评）。
---@param bookId string
---@param chapter_uid string|number
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Client:underlinesAsync(bookId, chapter_uid, cb)
    return getWebAsync("/web/book/underlines", { bookId = bookId, chapterUid = chapter_uid }, cb)
end

--- 按 range 批量拉段评：``reviews[]`` 每条 ``{ range, totalCount, maxIdx, hasMore, pageReviews[] }``。
--- 分页把上一页回包的 ``maxIdx`` 原样带回。
---@param bookId string
---@param chapter_uid string|number
---@param reviews { range: string, maxIdx: integer, count: integer, synckey: integer }[]
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Client:readReviewsAsync(bookId, chapter_uid, reviews, cb)
    return postWebAsync("/web/book/readReviews", {
        bookId = bookId,
        chapterUid = tonumber(chapter_uid) or chapter_uid,
        reviews = reviews,
    }, nil, cb)
end

return Client
