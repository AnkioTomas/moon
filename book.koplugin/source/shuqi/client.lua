--[[--
书旗网页接口。

搜索、分类、目录、免费正文不登录。登录支持手机验证码与官网 Cookie。
书架增删和阅读位置走书签同步，写入后另拉快照确认。

@module source.shuqi.client
--]]

local JSON = require("json")
local Mapper = require("source.shuqi.mapper")
local Request = require("http.request")
local Text = require("utils.text")
local _ = require("l10n").get("source.shuqi")

local Client = {}

local SOURCE_ID = "shuqi"
local NOVEL = "https://read.xiaoshuo1-sm.com/novel/i.php"
local CONTENT = "https://content.shuqireader.com"
local OCEAN = "https://ocean.shuqireader.com"
local BOOKMARK = "https://jbookmark.shuqireader.com/api/v1/sync/bookmarks"
local ANON_USER = "8000000"

local env = {}
local login_epoch = 0

---@class ShuqiBookmarkRequest
---@field pending boolean
---@field start fun()
---@field job HttpJob|nil

---@class ShuqiBookmarkSession
---@field epoch integer
---@field requests ShuqiBookmarkRequest[]
local BookmarkSession = {}
BookmarkSession.__index = BookmarkSession

---@return ShuqiBookmarkSession
function BookmarkSession.new()
    return setmetatable({ epoch = login_epoch, requests = {} }, BookmarkSession)
end

---@param entry ShuqiBookmarkRequest
function BookmarkSession:remove(entry)
    for index, request in ipairs(self.requests) do
        if request == entry then
            table.remove(self.requests, index)
            if index == 1 and self.requests[1] then
                require("ui/uimanager"):nextTick(
                    require("ui.guard").wrap("shuqi.bookmarks.start", self.requests[1].start))
            end
            return
        end
    end
end

-- 同一账号的书签接口拒绝并发请求（10006）；队列归登录会话所有。
---@param url string
---@param body string
---@param options HttpRequestOpts
---@param cb fun(raw: string|nil, err: any)
---@return HttpJob
function BookmarkSession:post(url, body, options, cb)
    ---@type ShuqiBookmarkRequest
    local entry
    entry = {
        pending = true,
        start = function()
            if not entry.pending then return end
            if self.epoch ~= login_epoch then
                entry.pending = false
                self:remove(entry)
                cb(nil, _("登录状态已变化，请重试"))
                return
            end
            local job = Request.post(url, body, options, function(raw, err)
                if not entry.pending then return end
                entry.pending = false
                self:remove(entry)
                cb(raw, err)
            end)
            if entry.pending then entry.job = job end
        end,
    }
    self.requests[#self.requests + 1] = entry
    if #self.requests == 1 then entry.start() end
    return { cancel = function()
        if not entry.pending then return end
        entry.pending = false
        if entry.job then entry.job.cancel() end
        self:remove(entry)
    end }
end

function Client.reset()
    env = {}
    login_epoch = login_epoch + 1
end

function Client.load()
    env = { bookmarks = env.bookmarks }
    local cfg = require("utils.settings").getSource(SOURCE_ID)
    env.token = cfg.token
    env.user_id = cfg.user_id
    env.imei = cfg.imei
    env.umidtoken = cfg.umidtoken
    env.wua = cfg.wua
end

---@return boolean
function Client.loggedIn()
    if not env.token then Client.load() end
    local cfg = require("utils.settings").getSource(SOURCE_ID)
    return cfg.logged_in == true and type(cfg.token) == "string" and cfg.token ~= ""
end

---@param session { token: string, user_id: string|nil, name: string }
---@param browser { fingerprint: string|nil, umidtoken: string|nil, wua: string|nil }|nil
function Client.persist(session, browser)
    local settings = require("utils.settings")
    local cfg = settings.getSource(SOURCE_ID)
    cfg.token = session.token
    cfg.user_id = session.user_id
    cfg.name = session.name
    cfg.logged_in = true
    cfg.imei = browser and browser.fingerprint or nil
    cfg.umidtoken = browser and browser.umidtoken or nil
    cfg.wua = browser and browser.wua or nil
    settings.saveSource(SOURCE_ID)
    login_epoch = login_epoch + 1
    Client.load()
end

---@param cb fun(wire: table|nil, err: string|nil)
local function decode(cb)
    return function(raw, err)
        if not raw or raw == "" then cb(nil, err and tostring(err) or _("请求失败")); return end
        local ok, wire = pcall(JSON.decode, raw)
        if not ok or type(wire) ~= "table" then cb(nil, _("响应无效")); return end
        cb(wire)
    end
end

---@return table
local function opts()
    return {
        accept = "application/json",
        headers = { Accept = "application/json", Referer = "https://t.shuqi.com/" },
        timeout = require("http.timeout").net(1),
    }
end

---@param url string
---@param cb fun(wire: table|nil, err: string|nil)
local function get(url, cb)
    return Request.get(url, opts(), decode(cb))
end

---@param book_id string
---@return string timestamp
---@return table fields
local function contentFields(book_id)
    if env.token == nil then Client.load() end
    local timestamp = tostring(os.time())
    local user_id = env.user_id
    if type(user_id) ~= "string" or user_id == "" then user_id = ANON_USER end
    return timestamp, { user_id = user_id, bookId = book_id, timestamp = timestamp }
end

---@param keyword string
---@param cb fun(books: Book[]|nil, err: string|nil)
---@return HttpJob
function Client.searchAsync(keyword, cb)
    local timestamp = tostring(os.time())
    local url = NOVEL .. "?" .. Text.formEncode({
        ["do"] = "is_search",
        userId = ANON_USER,
        platform = "3",
        p = "3",
        q = keyword,
        page = "1",
        size = "20",
        filterMigu = "1",
        ver = "",
        timestamp = timestamp,
        sign = Mapper.searchSign(timestamp),
    })
    return get(url, function(wire, err)
        if not wire then cb(nil, err); return end
        local books, reason = Mapper.searchBooks(wire)
        if not books then cb(nil, reason or _("请求失败")); return end
        cb(books)
    end)
end

---@param cb fun(wire: table|nil, err: string|nil)
---@return HttpJob
function Client.categoriesAsync(cb)
    local timestamp = tostring(os.time())
    local url = CONTENT .. "/openapi/rankv2/class?" .. Text.formEncode({
        user_Id = ANON_USER,
        timestamp = timestamp,
        imei = "",
        sn = "",
        tk = "",
        platform = "3",
        p = "3",
        sign = Mapper.rankSign(timestamp),
    })
    return get(url, cb)
end

---@param tag string|nil
---@param cb fun(books: Book[]|nil, err: string|nil)
---@return HttpJob
function Client.rankAsync(tag, cb)
    local timestamp = tostring(os.time())
    local query = {
        ["do"] = "is_caterank",
        userId = ANON_USER,
        platform = "3",
        p = "3",
        page = "1",
        size = "20",
        filterMigu = "1",
        timestamp = timestamp,
        sign = Mapper.rankSign(timestamp),
    }
    if type(tag) == "string" and tag ~= "" then query.tag = tag end
    return get(NOVEL .. "?" .. Text.formEncode(query), function(wire, err)
        if not wire then cb(nil, err); return end
        local books, reason = Mapper.searchBooks(wire)
        if not books then cb(nil, reason or _("请求失败")); return end
        cb(books)
    end)
end

---@param node string|nil
---@param page integer
---@param cb fun(html: string|nil, err: string|nil)
---@return HttpJob
function Client.storeAsync(node, page, cb)
    local query = node and Mapper.storeNode(node)
    if node and not query then return require("source.base").defer(cb, nil, _("响应无效")) end
    local options = opts()
    options.accept = "text/html"
    options.headers = { Accept = "text/html", Referer = "https://www.shuqi.com/store" }
    return Request.get("https://www.shuqi.com/store?" .. (query and query .. "&" or "") .. "page=" .. page, options, cb)
end

---@param book_id string
---@param page integer
---@param cb fun(page: table|nil, err: string|nil)
---@return HttpJob
function Client.reviewsAsync(book_id, page, cb)
    local url = "https://comment.alwx.alibaba.com/novel/i.php?" .. Text.formEncode({
        ["do"] = "sp_get", bookId = book_id, fetch = "merge",
        sqUid = ANON_USER, source = "store", size = 20, page = page, score = "yes",
    })
    return get(url, function(wire, err)
        if not wire then cb(nil, err); return end
        local result = Mapper.reviews(wire, book_id)
        cb(result, not result and _("响应无效") or nil)
    end)
end

---@param book_id string
---@param cb fun(book: Book|nil, err: string|nil)
---@return HttpJob
function Client.detailAsync(book_id, cb)
    local _timestamp, fields = contentFields(book_id)
    fields.sign = Mapper.contentSign(fields)
    fields.platform = "0"
    return Request.post(CONTENT .. "/openapi/book/info", Text.formEncode(fields), opts(), function(raw, err)
        if not raw or raw == "" then cb(nil, err and tostring(err) or _("请求失败")); return end
        local ok, wire = pcall(JSON.decode, raw)
        local book = ok and Mapper.detail(wire) or nil
        if not book then cb(nil, _("请求失败")); return end
        cb(book)
    end)
end

---@param book_id string
---@param cb fun(toc: BookChapter[]|nil, err: string|nil)
---@return HttpJob
function Client.chaptersAsync(book_id, cb)
    local _timestamp, fields = contentFields(book_id)
    fields.sign = Mapper.contentSign(fields)
    fields.platform = "0"
    fields.tk = env.token or ""
    fields.imei = env.imei or ""
    fields.sn = env.imei or ""
    local url = CONTENT .. "/openapi/book/chapterlist?" .. Text.formEncode(fields)
    return get(url, function(wire, err)
        if not wire then cb(nil, err); return end
        local toc = Mapper.chapters(wire)
        if not toc then cb(nil, _("请求失败")); return end
        cb(toc)
    end)
end

---@param url string|nil
---@param cb fun(text: string|nil, err: string|nil)
---@return HttpJob|nil
function Client.contentAsync(url, cb)
    if type(url) ~= "string" or url == "" then cb(nil, _("本章未购买")); return nil end
    return get(url, function(wire, err)
        if not wire then cb(nil, err); return end
        local text, reason = Mapper.chapterText(wire)
        if not text then cb(nil, reason and _(reason) or _("请求失败")); return end
        cb(text)
    end)
end

---@param fields table
---@return string
local function gatewayBody(fields)
    fields.sign = Mapper.gatewaySign(fields)
    fields.key = "sq_h5_gateway"
    return Text.formEncode(fields)
end

---@param session table
---@param browser table|nil
---@param cb fun(session: table|nil, err: string|nil)
local function acceptSession(session, browser, cb)
    if not session.user_id then cb(nil, _("书旗账号缺少用户编号")); return end
    local cfg = require("utils.settings").getSource(SOURCE_ID)
    if cfg.logged_in and cfg.user_id ~= session.user_id then
        local cleared = require("source.logout").clear(SOURCE_ID, function()
            cfg.token, cfg.user_id, cfg.name = nil, nil, nil
            cfg.logged_in, cfg.imei, cfg.umidtoken, cfg.wua = nil, nil, nil, nil
            require("utils.settings").saveSource(SOURCE_ID)
            Client.reset()
        end)
        if not cleared then cb(nil, _("准备本地同步失败")); return end
    end
    Client.persist(session, browser)
    cb(session)
end

---@param wire table|nil
---@return string
local function loginError(wire)
    if type(wire) ~= "table" then return _("登录响应无效") end
    local message = wire.message or wire.msg
    if type(message) == "string" and message ~= "" then return message end
    local status = wire.status or wire.state
    if tonumber(status) == 200 then return _("登录响应无效") end
    if type(status) == "string" or type(status) == "number" then
        return string.format(_("书旗登录失败（状态：%s）"), tostring(status))
    end
    return _("登录响应无效")
end

--- 只向官方账号接口提交 Cookie 中的会话，不发送其他 Cookie，不缓存账号响应。
---@param cookie string
---@param cb fun(session: table|nil, err: string|nil)
---@return HttpJob|nil
function Client.loginCookieAsync(cookie, cb)
    local candidate = Mapper.cookieSession(require("source.cookie_login").parse(cookie))
    if not candidate then return require("source.base").defer(cb, nil, _("书旗 Cookie 缺少有效的登录凭证")) end
    local epoch, cancelled = login_epoch, false
    local fields = { userId = candidate.user_id, sqSv = "1.0" }
    fields.sign = Mapper.gatewaySign(fields)
    fields.key = "sq_h5_gateway"
    fields._public = Text.formEncode({
        platform = "0", user_id = candidate.user_id,
        imei = candidate.fingerprint or "", sn = candidate.fingerprint or "",
    })
    local options = opts()
    options.cache_ttl = 0
    options.headers.Authorization = "Bearer " .. candidate.token
    local job = Request.get(OCEAN .. "/webapi/jaccount/accountapi/v1/sapi/account/userBaseInfo?"
        .. Text.formEncode(fields), options, function(raw, err)
        if cancelled then return end
        if epoch ~= login_epoch then cb(nil, _("登录状态已变化，请重试")); return end
        if not raw or raw == "" then cb(nil, err and tostring(err) or _("请求失败")); return end
        local ok, wire = pcall(JSON.decode, raw)
        if not ok then cb(nil, _("登录响应无效")); return end
        local account = Mapper.account(wire, candidate.user_id)
        if not account then cb(nil, loginError(wire)); return end
        candidate.name = account.name
        acceptSession(candidate, { fingerprint = candidate.fingerprint }, cb)
    end)
    return { cancel = function()
        cancelled = true
        if job then job.cancel() end
    end }
end

--- 发送登录短信。手机号只在设备上，滑块字符串由远程页交回。
---@param phone string
---@param captcha string
---@param cb fun(ok: boolean|nil, err: string|nil)
---@param browser { user_agent: string|nil }|nil
---@return HttpJob
function Client.sendCodeAsync(phone, captcha, cb, browser)
    local timestamp = tostring(os.time())
    local fields = {
        mobile = phone,
        captcha = captcha,
        aliyunCheck = "1",
        type = "1010",
        userId = ANON_USER,
        platform = "0",
        appVer = "",
        placeId = "",
        timestamp = timestamp,
        sqSv = "1.0",
        _public = Text.formEncode({
            platform = "0",
            priority = "code",
            redirect_uri = "https://t.shuqi.com/myself",
        }),
    }
    local options = opts()
    if browser and browser.user_agent and browser.user_agent ~= "" then options.headers["User-Agent"] = browser.user_agent end
    return Request.post(OCEAN .. "/api/jaccount/sso/captcha/sendCode", gatewayBody(fields), options, function(raw, err)
        if not raw or raw == "" then cb(nil, err and tostring(err) or _("请求失败")); return end
        local ok, wire = pcall(JSON.decode, raw)
        if not ok then cb(nil, _("请求失败")); return end
        local sent, reason = Mapper.sent(wire)
        if not sent then cb(nil, reason or _("请求失败")); return end
        cb(true)
    end)
end

--- 验证码登录。browser 是远程页带回来的设备指纹，没有就空着。
---@param phone string
---@param code string
---@param browser { fingerprint: string|nil, umidtoken: string|nil, wua: string|nil, user_agent: string|nil }|nil
---@param cb fun(session: table|nil, err: string|nil)
---@return HttpJob
function Client.loginAsync(phone, code, browser, cb)
    local cancelled, epoch = false, login_epoch
    local mark = browser or {}
    local fingerprint = type(mark.fingerprint) == "string" and mark.fingerprint or ""
    local fields = {
        imei = fingerprint,
        sn = fingerprint,
        umidtoken = type(mark.umidtoken) == "string" and mark.umidtoken or "",
        wua = type(mark.wua) == "string" and mark.wua or "",
        timestamp = tostring(os.time()),
        sqSv = "1.0",
        platform = "0",
        mobile = phone,
        vcode = code,
        loginToken = "",
        pageSource = "",
        appName = "sqH5",
        agent = "chrome",
    }
    local options = opts()
    if mark.user_agent and mark.user_agent ~= "" then options.headers["User-Agent"] = mark.user_agent end
    local job = Request.post(OCEAN .. "/api/jaccount/sso/vcode/login", gatewayBody(fields), options, function(raw, err)
        if cancelled then return end
        if epoch ~= login_epoch then cb(nil, _("登录状态已变化，请重试")); return end
        if not raw or raw == "" then cb(nil, err and tostring(err) or _("请求失败")); return end
        local ok, wire = pcall(JSON.decode, raw)
        if not ok then
            cb(nil, raw:match("^%s*<") and _("书旗登录触发安全验证，请在官网登录后导入 Cookie。") or _("登录响应无效"))
            return
        end
        local session, reason = Mapper.session(wire)
        if not session then cb(nil, reason or loginError(wire)); return end
        acceptSession(session, mark, cb)
    end)
    return { cancel = function()
        cancelled = true
        if job then job.cancel() end
    end }
end

---@param bookmark table[]
---@param cb fun(books: Book[]|nil, err: string|nil, wire: table|nil)
---@return HttpJob|nil
local function syncAsync(bookmark, cb)
    if not Client.loggedIn() then cb(nil, _("未登录书旗")); return nil end
    if type(env.user_id) ~= "string" or env.user_id == "" then
        cb(nil, _("书旗账号缺少用户编号"))
        return nil
    end
    -- 页面把 user.id 按数字放进 data.userid。字符串对不上账号，同步回空书架。
    -- 空表会被编成 {}。书签接口认 bookmark 是数组，对象的话直接回空书架。
    local marks = bookmark
    if JSON.util and JSON.util.InitArray then marks = JSON.util.InitArray(bookmark) end
    local epoch = login_epoch
    local data = JSON.encode({
        userid = tonumber(env.user_id) or env.user_id,
        t = os.time(),
        get_data = "1",
        bookmark = marks,
        coverType = "0",
        client_bid_set = {},
        placeid = "",
    })
    local body = Text.formEncode({
        platform = "0",
        imei = env.imei or "",
        sn = env.imei or "",
        tk = env.token,
        user_id = env.user_id,
        data = data,
    })
    local url = BOOKMARK .. "?" .. Text.formEncode({ ["_"] = tostring(os.time()), nom9 = "1" })
    if not env.bookmarks or env.bookmarks.epoch ~= epoch then
        env.bookmarks = BookmarkSession.new()
    end
    return env.bookmarks:post(url, body, opts(), function(raw, err)
        if epoch ~= login_epoch then cb(nil, _("登录状态已变化，请重试")); return end
        if not raw or raw == "" then
            cb(nil, err and tostring(err) or _("书旗登录已失效，请点「重新登录」，用手机验证码登录。"))
            return
        end
        local ok, wire = pcall(JSON.decode, raw)
        if not ok then cb(nil, _("请求失败")); return end
        local books, reason = Mapper.shelf(wire)
        if not books then
            local status = type(wire) == "table" and tonumber(wire.status)
            if status then reason = (reason or _("请求失败")) .. " (" .. status .. ")" end
            cb(nil, reason or _("书旗登录已失效，请点「重新登录」，用手机验证码登录。"))
            return
        end
        cb(books, nil, wire)
    end)
end

---@param cb fun(books: Book[]|nil, err: string|nil)
---@return HttpJob|nil
function Client.shelfAsync(cb)
    return syncAsync({}, cb)
end

---@param stable_id string
---@param action integer
---@param extra { title: string|nil, author: string|nil, cover: string|nil }|nil
---@param cb fun(ok: boolean|nil, err: string|nil)
local function changeAsync(stable_id, action, extra, cb)
    -- 页面 add_time 是 13 位毫秒，last_update 是秒字符串，书签行带书名。
    local now_ms = os.time() * 1000
    local row = {
        bid = tonumber(stable_id) or stable_id,
        action = action,
        percent = 0,
        source = 1,
        offset = 0,
        state = "",
        offsetType = "",
        add_time = now_ms,
        last_update = tostring(os.time()),
    }
    if type(extra) == "table" then
        if type(extra.title) == "string" and extra.title ~= "" then row.title = extra.title end
        if type(extra.author) == "string" and extra.author ~= "" then row.author = extra.author end
        if type(extra.cover) == "string" and extra.cover ~= "" then row.cover = extra.cover end
    end
    local cancelled, job, pending = false, nil, true
    local first = syncAsync({ row }, function(books, err)
        pending = false
        if cancelled then return end
        if not books then cb(nil, err or (action == 3 and _("移出书旗书架失败") or _("加入书旗书架失败"))); return end
        job = Client.shelfAsync(function(fresh, reason)
            if cancelled then return end
            if not fresh then cb(nil, reason); return end
            local present = false
            for _idx, book in ipairs(fresh) do
                if book.stable_id == stable_id then present = true; break end
            end
            if present ~= (action == 1) then cb(nil, _("同步结果未确认，请重试")); return end
            cb(true)
        end)
    end)
    if pending then job = first end
    return { cancel = function()
        cancelled = true
        if job then job.cancel() end
    end }
end

---@param stable_id string
---@param cb fun(ok: boolean|nil, err: string|nil)
function Client.addAsync(stable_id, cb)
    local cancelled, job, pending = false, nil, true
    local first = Client.detailAsync(stable_id, function(book, err)
        pending = false
        if cancelled then return end
        if not book then cb(nil, err); return end
        job = changeAsync(stable_id, 1, { title = book.title, author = book.authors, cover = book.cover }, cb)
    end)
    if pending then job = first end
    return { cancel = function()
        cancelled = true
        if job then job.cancel() end
    end }
end

---@param stable_id string
---@param cb fun(ok: boolean|nil, err: string|nil)
function Client.removeAsync(stable_id, cb)
    return changeAsync(stable_id, 3, nil, cb)
end

--- 阅读位置和书架是同一条书签。拉取是空书签同步，按 bid 取 chapterid。
---@param stable_id string
---@param cb fun(mark: { chapter_id: string, title: string|nil, fraction: number }|nil, err: string|nil)
---@return HttpJob|nil
function Client.progressAsync(stable_id, cb)
    return syncAsync({}, function(books, err, wire)
        if not books then cb(nil, err); return end
        cb(Mapper.mark(wire, stable_id))
    end)
end

--- 更新阅读位置用 action 2。percent 是万分比，和网页 `(章序 / 总章数) * 10000` 一致。
--- 加入书架仍是 action 1，那时候还没有章节位置。
---@param stable_id string
---@param chapter_id string
---@param title string|nil
---@param fraction number
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return HttpJob|nil
function Client.putProgressAsync(stable_id, chapter_id, title, fraction, cb)
    local now = os.time()
    local percent = math.floor((tonumber(fraction) or 0) * 10000 + 0.5)
    if percent < 1 then percent = 1 end
    if percent > 10000 then percent = 10000 end
    local row = {
        bid = tonumber(stable_id) or stable_id,
        action = 2,
        percent = percent,
        source = 1,
        offset = 0,
        state = "",
        chapterid = tonumber(chapter_id) or chapter_id,
        cname = title or "",
        add_time = now * 1000,
        last_update = tostring(now),
    }
    local cancelled, job, pending = false, nil, true
    local first = syncAsync({ row }, function(books, err)
        pending = false
        if cancelled then return end
        if not books then cb(nil, err or _("书旗进度保存失败")); return end
        job = Client.progressAsync(stable_id, function(mark, reason)
            if cancelled then return end
            if reason then cb(nil, reason); return end
            -- 服务端回读只保留三位小数，按同一精度确认，不能把舍入当成上传失败。
            if not mark or mark.chapter_id ~= chapter_id
                or math.floor(mark.fraction * 1000 + 0.5) ~= math.floor(percent / 10 + 0.5) then
                cb(nil, _("同步结果未确认，请重试"))
                return
            end
            cb(true)
        end)
    end)
    if pending then job = first end
    return { cancel = function()
        cancelled = true
        if job then job.cancel() end
    end }
end

return Client
