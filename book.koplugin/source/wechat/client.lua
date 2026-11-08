--[[--
微信读书协议客户端：只返回 wire，不做领域转换（仅异步）。

书架、章节、想法、划线、搜索、进度与统计走 Eink ``i.weread.qq.com``（App 协议）。
进度与时长都是 ``POST /book/read``。跨了多个小时，或补报离线积压，改走 ``POST /book/batchUploadProgress``。

@module koplugin.book.source.wechat.client
--]]

local JSON = require("json")
local logger = require("utils.log")
local Auth = require("source.wechat.auth")
local Eink = require("source.wechat.eink")
local Text = require("utils.text")
local _ = require("l10n").get("source.wechat")

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
            cb(nil, Eink.userMessage(errcode, data.errmsg or data.errMsg))
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

--- 书城搜索（App ``GET /store/search``）。回包书在 ``data[]``，每条 ``bookInfo``；补成 ``books[]`` 交给 mapper。
---@param keyword string
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Client:searchAsync(keyword, cb)
    return Eink.callAsync("GET", "/store/search", {
        query = {
            keyword = keyword, author = "", authorVids = "", categoryId = "",
            count = 20, maxIdx = 0, type = 0, v = 2, outer = 0, fromBookId = "",
            scope = 0, scene = 0, filterType = 0, filterField = "", queryUid = "", isQueryWord = 0,
        },
    }, function(data, err)
        if not data then
            cb(nil, err)
            return
        end
        if type(data.books) ~= "table" then
            data.books = type(data.data) == "table" and data.data or {}
        end
        cb(data)
    end)
end

--- 书城榜单与分类目录：``data[]`` 分组，``categories[]`` 里 CategoryId / title / sublist（公开接口，无需登录）。
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Client:storeCategoriesAsync(cb)
    return getWebAsync("/web/categories", {}, cb)
end

--- 榜单 / 分类下的书：``books[]`` 同搜索（bookInfo），一次 20 本，maxIndex 是偏移，hasMore=1 还有。
---@param category_id string
---@param offset integer
---@param ranking boolean 榜单必须带 rank=1，分类带了反而是空
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Client:storeBooksAsync(category_id, offset, ranking, cb)
    local query = { maxIndex = offset, rank = ranking and 1 or nil }
    return getWebAsync("/web/bookListInCategory/" .. Text.urlEncode(category_id), query, cb)
end

--- 全量拉取书架（synckey=0 表示不做增量）。/shelf/sync 无分页参数、服务端一发全量。
--- bookCount 含专辑、公众号等不在 books 里的条目，不能拿它卡这次同步。
--- spill：回包超过 ShelfImport.LIMIT 时不解码，原文落盘交给网页端分批导入，cb 收到 nil + 说明。
---@param cb fun(data: table|nil, err: string|nil) 原始 wire 数据
---@param spill boolean|nil
---@param open_import boolean|nil 是否打开导入页（仅用户主动刷新）
---@return { cancel: fun() }|nil
function Client:shelfSyncAsync(cb, spill, open_import)
    local ShelfImport = require("source.wechat.shelf_import")
    -- 待导入快照保留到用户明确完成或丢弃；后台同步不重复弹导入页。
    if spill and ShelfImport.size() then
        if open_import then
            require("utils.extension").call("web.open_page", ShelfImport.PAGE, _("微信书架导入"), ShelfImport.TOO_LARGE)
        end
        return require("source.base").defer(cb, nil, ShelfImport.TOO_LARGE)
    end
    local Awake = require("utils.awake")
    -- 大书架下载 + 落盘要几分钟，期间别让设备睡下去；回调或取消时放开。
    Awake.hold("wechat_shelf", true)
    local handle = Eink.callAsync("GET", "/shelf/sync", {
        query = { synckey = 0, teenmode = 0, album = 1, onlyBookid = 0, localBookCount = 0 },
        max_body = spill and ShelfImport.LIMIT or nil,
    }, function(data, err, meta)
        if meta and meta.oversize then
            local ok, werr = ShelfImport.stash(data.body)
            Awake.hold("wechat_shelf", false)
            if ok and open_import then
                require("utils.extension").call("web.open_page", ShelfImport.PAGE, _("微信书架导入"), ShelfImport.TOO_LARGE)
            end
            cb(nil, ok and ShelfImport.TOO_LARGE or werr)
            return
        end
        Awake.hold("wechat_shelf", false)
        cb(data, err)
    end)
    if not handle then
        Awake.hold("wechat_shelf", false)
        return nil
    end
    return { cancel = function()
        Awake.hold("wechat_shelf", false)
        handle.cancel()
    end }
end

--- 增量拉书架索引：自 synckey 以来删了哪些（removed）、变了哪些（bookIds，只要 id）、
--- 分组与专辑变更（archive / albumRemoved）、服务端总数（bookCount）与新 synckey。
--- onlyBookid=1 不带元数据，变更的书再用 shelfSyncBooksAsync 按 id 补。
---@param synckey number 上次同步保存的游标
---@param local_count integer 本地在架书数（服务端据此判断两边是否对得齐）
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Client:shelfSyncIdsAsync(synckey, local_count, cb)
    return Eink.callAsync("GET", "/shelf/sync", {
        query = { synckey = synckey, teenmode = 0, album = 1, onlyBookid = 1, localBookCount = local_count },
    }, cb)
end

--- 按 id 补拉书架行（增量里变更的书）：回包 { books, bookProgress, albums, emptyInfoIds }。
---@param book_ids string[]
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Client:shelfSyncBooksAsync(book_ids, cb)
    return Eink.callAsync("POST", "/shelf/syncbook", {
        body = { bookIds = book_ids, albumIds = {} },
    }, cb)
end

--- 加入微信读书书架。
---@param bookId string
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Client:addToShelfAsync(bookId, cb)
    return Eink.callAsync("POST", "/shelf/add", { body = { bookIds = { bookId }, albumIds = {} } }, cb)
end

--- 从微信读书书架删除。
---@param bookId string
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Client:removeFromShelfAsync(bookId, cb)
    return Eink.callAsync("POST", "/shelf/delete", {
        body = { bookIds = { bookId }, albumIds = {}, archiveIds = {} },
    }, cb)
end

--- 写分组：同一 archiveId 带完整 bookIds 即整体替换成员；新分组的 archiveId 由客户端取秒级时间戳。
---@param archive_id integer
---@param name string
---@param book_ids string[]
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Client:saveArchiveAsync(archive_id, name, book_ids, cb)
    return Eink.callAsync("POST", "/shelf/archive", {
        body = { albumIds = {}, archiveId = archive_id, bookIds = book_ids, name = name },
    }, cb)
end

--- 拉取书籍详情（含书籍版本号）。
---@param bookId string 微信读书 bookId，即 stable_id
---@param cb fun(data: table|nil, err: string|nil) 原始 wire 数据
---@return { cancel: fun() }|nil
function Client:bookInfoAsync(bookId, cb)
    return Eink.callAsync("GET", "/book/info", {
        query = { bookId = bookId, myzy = 1, source = "reading", teenmode = 0 },
    }, cb)
end

--- 拉取整本书的章节目录。
---@param bookId string 微信读书 bookId，即 stable_id
---@param cb fun(data: table|nil, err: string|nil) 原始 wire 数据
---@return { cancel: fun() }|nil
function Client:chapterInfosAsync(bookId, cb)
    return Eink.callAsync("POST", "/book/chapterInfos", {
        body = { bookIds = { bookId }, synckeys = { 0 }, teenmode = 0 },
        idempotent = true,
    }, cb)
end

--- 拉取云端阅读进度；带毫秒时间戳参数避开中间层缓存。
---@param bookId string 微信读书 bookId，即 stable_id
---@param cb fun(data: table|nil, err: string|nil) 原始 wire 数据
---@return { cancel: fun() }|nil
function Client:getProgressAsync(bookId, cb)
    return Eink.callAsync("GET", "/book/getProgress", {
        query = { bookId = bookId, t = os.time() * 1000 + math.random(0, 999) },
    }, cb)
end

--- 上报阅读进度：App ``POST /book/read``，本地坐标，可带尚未上报的小时桶。不下载网页阅读页。
---@param bookId string
---@param opts { progress: number, current_progress?: number, chapter_uid: string|number, chapter_idx?: number, chapter_offset?: number, chapter_fraction?: number, summary?: string, book_version?: integer, hours?: WechatAppHour[] }
---@param cb fun(data: table|nil, err: any, meta?: { permanent?: boolean })
---@return { cancel: fun() }
function Client:putProgressAsync(bookId, opts, cb)
    if not Eink.credentials() then
        require("ui/uimanager"):nextTick(function() cb(nil, _("请先扫码登录微信读书墨水屏")) end)
        return { cancel = function() end }
    end
    local cancelled, current = false, nil
    local function bind(next_job)
        if next_job then current = next_job end
    end
    bind(self:guestTokenAsync(function(token, err)
        if cancelled then return end
        if not token then
            cb(nil, err)
            return
        end
        local creds = Eink.credentials()
        if not creds then
            cb(nil, _("请先扫码登录微信读书墨水屏"))
            return
        end
        local function percentOf(value)
            return math.max(0, math.min(100, math.floor(tonumber(value) or 0)))
        end
        local current_raw = opts.current_progress
        if current_raw == nil then current_raw = opts.progress end
        local current = percentOf(current_raw)
        local hours = type(opts.hours) == "table" and opts.hours or {}
        local body = require("source.wechat.app").readBody({
            vid = creds.vid,
            device_id = creds.device_id,
            install_id = Eink.installId(),
            guest_token = token,
            book_id = bookId,
            chapter_uid = tonumber(opts.chapter_uid) or 0,
            chapter_idx = opts.chapter_idx or 0,
            chapter_offset = opts.chapter_offset or 0,
            chapter_progress = math.max(0, math.min(100,
                math.floor((tonumber(opts.chapter_fraction) or 0) * 100 + 0.5))),
            progress = percentOf(opts.progress),
            current_progress = current,
            summary = opts.summary,
            book_version = opts.book_version,
            hours = hours,
            -- 一个小时以内走 /book/read。跨小时走批量，resend=0。
            resend = #hours > 1 and 0 or nil,
        })
        local function done(data, push_err)
            if cancelled then return end
            if not data then return cb(nil, push_err) end
            cb({ ok = true })
        end
        if body.isResendReadingInfo ~= nil then
            bind(self:reportBatchAsync({ body }, done))
        else
            bind(self:reportAppReadAsync(body, done))
        end
    end))
    return { cancel = function()
            cancelled = true
            if current and current.cancel then current.cancel() end
        end }
end

--- 标记读完。App 读到结尾走 ``POST /book/markstatus``，书架的 finishReading 从这里来。
---@param bookId string
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Client:markFinishedAsync(bookId, cb)
    return Eink.callAsync("POST", "/book/markstatus", {
        body = { bookId = tostring(bookId), status = 4, finishInfo = 0, isCancel = 0, auto = 1 },
    }, cb)
end

--- App 防重放签名用的 guest_token（``/feature`` 配置里的同名项），进程内缓存。
---@type string|nil
local guest_token

--- 离线批量签名用的 token（``GET /config?token=1``）。只留在进程里，-2054 作废。
---@type string|nil
local read_trouble

---@param cb fun(token: string|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Client:guestTokenAsync(cb)
    if guest_token then
        cb(guest_token)
        return nil
    end
    return Eink.callAsync("GET", "/feature", { query = { synckey = 0 } }, function(data, err)
        if not data then
            cb(nil, err)
            return
        end
        -- 万一拿不到就用空串签，由服务端决定收不收。
        local token = type(data.feature) == "table" and data.feature.guest_token
        guest_token = type(token) == "string" and token or ""
        if guest_token ~= "" then Eink.setGuestToken(guest_token) end
        cb(guest_token)
    end)
end

--- 离线批量的外层 token。空串不缓存，下次再取。
---@param cb fun(token: string|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Client:encryptTokenAsync(cb)
    if read_trouble and read_trouble ~= "" then
        cb(read_trouble)
        return nil
    end
    return Eink.callAsync("GET", "/config", { query = { token = 1 } }, function(data, err)
        local token = data and data.token
        if type(token) ~= "string" or token == "" then
            cb(nil, err or _("上报响应异常"))
            return
        end
        read_trouble = token
        cb(token)
    end)
end

--- 上报阅读时长（App ``/book/read``，按小时分桶，可补报离线时段）。
--- 写请求不自动重放：续期后由调用方下一轮重推（未确认的行仍是脏行）。
---@param body table 已签名的请求体
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Client:reportAppReadAsync(body, cb)
    return Eink.callAsync("POST", "/book/read", { body = body }, function(data, err)
        if not data then
            cb(nil, err)
            return
        end
        if tonumber(data.succ) ~= 1 then
            logger.warn("weread app report not accepted")
            cb(nil, _("上报响应异常"))
            return
        end
        cb(data)
    end)
end

--- 读取网页阅读器会话参数；仅用于维持网页端「在读」状态。
---@param bookId string
---@param cb fun(state: { psvts: string, pclts: string|nil, token: string|nil }|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Client:readerStateAsync(bookId, cb)
    local url = require("source.wechat.protocol").readerUrl(bookId)
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

--- 上报网页阅读状态；调用方固定传 ``rt=0``，阅读时长只由 App 小时桶上报。
---@param body table 已签名的请求体
---@param referer string
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Client:reportReadAsync(body, referer, cb)
    return postWebAsync("/web/book/read", body, referer, function(data, err)
        if not data then
            cb(nil, err)
            return
        end
        if not (data.succ == true or tonumber(data.succ) == 1 or data.synckey ~= nil) then
            logger.warn("weread web presence not accepted")
            cb(nil, _("上报响应异常"))
            return
        end
        cb(data)
    end)
end

--- 离线上报（App ``POST /book/batchUploadProgress``）。
--- books 是已经签过名的单本体。外层签名用 /config 的 token；-2054 丢掉 token 再签一次。
---@param books table[]
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client:reportBatchAsync(books, cb)
    local cancelled, current = false, nil
    local function bind(next_job)
        if next_job then current = next_job end
    end
    local function attempt(n)
        bind(self:encryptTokenAsync(function(token, err)
            if cancelled then return end
            if not token then
                cb(nil, err)
                return
            end
            local body = require("source.wechat.app").batchBody(books, token)
            bind(Eink.callAsync("POST", "/book/batchUploadProgress", { body = body }, function(data, post_err, meta)
                if cancelled then return end
                if n == 1 and type(meta) == "table" and meta.errcode == -2054 then
                    read_trouble = nil
                    attempt(2)
                    return
                end
                if not data or tonumber(data.succ) ~= 1 then
                    logger.warn("weread app batch report not accepted")
                    cb(nil, post_err or _("上报响应异常"))
                    return
                end
                cb(data)
            end))
        end))
    end
    attempt(1)
    return { cancel = function()
        cancelled = true
        if current and current.cancel then current.cancel() end
    end }
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
    local function fetch(max_idx, pages, legacy)
        -- 部分书（含 CB_ 自传书）用 App 同款参数会被回 -2003；首页失败时改用社区通用的 listType=11 再试一次。
        local query = legacy and {
            bookId = bookId, listType = 11, listMode = 0, mine = 1, synckey = 0,
        } or {
            bookId = bookId,
            listType = 1,
            listMode = 0,
            mine = 1,
            synckey = 0,
            count = MY_REVIEWS_PAGE,
            maxIdx = max_idx > 0 and max_idx or nil,
        }
        job = Eink.callAsync("GET", "/review/list", { query = query }, function(data, err)
            if cancelled then return end
            if type(data) ~= "table" or type(data.reviews) ~= "table" then
                if not first and not legacy then
                    fetch(0, 1, true)
                    return
                end
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
    return Eink.callAsync("POST", "/review/add", { body = body }, cb)
end

--- 修改划线下想法。
---@param body table
---@param cb fun(data: table|nil, err: any)
---@return { cancel: fun() }|nil
function Client:editReviewAsync(body, cb)
    return Eink.callAsync("POST", "/review/useredit", { body = body }, cb)
end

--- 删除想法。
---@param review_id string|number
---@param cb fun(data: table|nil, err: any)
---@return { cancel: fun() }|nil
function Client:deleteReviewAsync(review_id, cb)
    return Eink.callAsync("POST", "/review/delete", { body = { reviewId = tostring(review_id) } }, cb)
end

--- 更新划线样式和颜色。
---@param body table
---@param cb fun(data: table|nil, err: any)
---@return { cancel: fun() }|nil
function Client:updateBookmarkAsync(body, cb)
    return Eink.callAsync("POST", "/book/updateBookmark", { body = body }, cb)
end

--- 删除划线。
---@param bookmark_id string|number
---@param cb fun(data: table|nil, err: any)
---@return { cancel: fun() }|nil
function Client:removeBookmarkAsync(bookmark_id, cb)
    return Eink.callAsync("POST", "/book/removeBookmark", {
        body = { bookmarkIds = { tostring(bookmark_id) } },
    }, cb)
end

--- 上传单条划线。
---@param bookId string
---@param chapter_uid string|number
---@param body table
---@param cb fun(data: table|nil, err: any)
---@return { cancel: fun() }|nil
function Client:addBookmarkAsync(bookId, chapter_uid, body, cb)
    return Eink.callAsync("POST", "/book/addBookmark", { body = body }, cb)
end

--- 本章热门划线与段评锚点：``underlines[]`` 每条 ``{ range, count, type }``（type 0 = 只有段评）。
---@param bookId string
---@param chapter_uid string|number
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Client:underlinesAsync(bookId, chapter_uid, cb)
    return Eink.callAsync("GET", "/book/underlines", {
        query = { bookId = bookId, chapterUid = chapter_uid },
    }, cb)
end

--- 按 range 批量拉段评：``reviews[]`` 每条 ``{ range, totalCount, maxIdx, hasMore, pageReviews[] }``。
--- 分页把上一页回包的 ``maxIdx`` 原样带回。
---@param bookId string
---@param chapter_uid string|number
---@param reviews { range: string, maxIdx: integer, count: integer, synckey: integer }[]
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Client:readReviewsAsync(bookId, chapter_uid, reviews, cb)
    return Eink.callAsync("POST", "/book/readreviews", { body = {
        bookId = bookId,
        chapterUid = tonumber(chapter_uid) or chapter_uid,
        cht2sMode = "",
        reviews = reviews,
    } }, cb)
end

--- 一条想法及其评论。commentsCount 是本页条数，commentsMaxIdx 用上一页回包续拉（首页 0）。
--- likesCount 置 0：只要评论，不拉点赞用户列表。
---@param review_id string
---@param max_idx integer
---@param count integer
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Client:reviewSingleAsync(review_id, max_idx, count, cb)
    return Eink.callAsync("GET", "/review/single", { query = {
        reviewId = tostring(review_id),
        synckey = 0,
        commentsCount = count,
        commentsDirection = 0,
        commentsMaxIdx = max_idx,
        likesCount = 0,
    } }, cb)
end

return Client
