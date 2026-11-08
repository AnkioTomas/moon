--[[--
豆瓣阅读网页接口。

搜索、专栏目录和免费章节不登录也能读。正文密钥在匿名时是 SHA-256("anonymous")。
登录是豆瓣阅读 App 扫码：先跟到 accounts.arkread.com 的授权页，再轮询二维码。
扫码成功后授权页跳回 read.douban.com，会话是 Set-Cookie，解密密钥换成用户编号。

@module source.douban.client
--]]

local JSON = require("json")
local Mapper = require("source.douban.mapper")
local Request = require("http.request")
local Text = require("utils.text")
local _ = require("l10n").get("source.douban")

local Client = {}

local SOURCE_ID = "douban"
local READ_HOST = "read.douban.com"
local ACCOUNT_HOST = "accounts.arkread.com"
local READ = "https://" .. READ_HOST
local ACCOUNT = "https://" .. ACCOUNT_HOST
local LOGIN_URL = READ .. "/oidc/login?redir=https%3A%2F%2Fread.douban.com%2F"
local LOGIN_EXPIRED = "豆瓣阅读登录已失效，请点「重新登录」，用豆瓣阅读 App 扫码。"

local active = { jars = {} }
local anonymous = { jars = {}, public = true }
local login_epoch = 0
local article_cache = {}
local loaded = false

local function remember(host, header, session)
    if type(host) ~= "string" or type(header) ~= "string" or header == "" then return end
    session = session or active
    local jar = session.jars[host] or {}
    session.jars[host] = jar
    local name, value = header:match("^%s*([^=;%s]+)=([^;]*)")
    if name then jar[name] = value ~= "" and value or nil end
end

function Client.reset()
    active = { jars = {} }
    login_epoch = login_epoch + 1
    article_cache = {}
    loaded = false
end

function Client.load()
    active = { jars = {} }
    local cookie = require("utils.settings").getSource(SOURCE_ID).cookie
    for pair in (cookie or ""):gmatch("[^;]+") do remember(READ_HOST, pair) end
    loaded = true
end

---@param host string
---@return string|nil
function Client.cookieFor(host, session)
    local jar = (session or active).jars[host]
    if not jar then return nil end
    local names = {}
    for name in pairs(jar) do names[#names + 1] = name end
    table.sort(names)
    if #names == 0 then return nil end
    local parts = {}
    for _idx, name in ipairs(names) do parts[#parts + 1] = name .. "=" .. jar[name] end
    return table.concat(parts, "; ")
end

---@return boolean
function Client.loggedIn()
    local cfg = require("utils.settings").getSource(SOURCE_ID)
    return cfg.logged_in == true and type(cfg.user_id) == "string" and cfg.user_id ~= ""
        and type(cfg.cookie) == "string" and cfg.cookie ~= ""
end

---@return string|nil
function Client.userId()
    local cfg = require("utils.settings").getSource(SOURCE_ID)
    if cfg.logged_in == true and type(cfg.user_id) == "string" and cfg.user_id ~= "" then return cfg.user_id end
    return nil
end

---@param user { id: string, name: string }
local function persist(user, session)
    local settings = require("utils.settings")
    local cfg = settings.getSource(SOURCE_ID)
    cfg.cookie = Client.cookieFor(READ_HOST, session)
    cfg.user_id = user.id
    cfg.name = user.name
    cfg.logged_in = true
    settings.saveSource(SOURCE_ID)
    login_epoch = login_epoch + 1
    Client.load()
    active.read_csrf = session.read_csrf
    article_cache = {}
end

---@param url string
---@return string
local function hostOf(url)
    return url:match("^https://([^/?#]+)")
end

---@param code any
---@return boolean
local function httpOk(code)
    code = tonumber(code)
    return code ~= nil and code >= 200 and code < 300
end

---@param host string
---@param res table|nil
---@return string|nil
local function expired(host, res, cookie)
    if host == READ_HOST and tonumber(res and res.code) == 401
        and cookie == require("utils.settings").getSource(SOURCE_ID).cookie
        and Client.loggedIn() then
        return require("source.auth").expire(SOURCE_ID, _(LOGIN_EXPIRED))
    end
    return nil
end

---@param res table|nil
local function absorb(host, res, session)
    if not res then return end
    for _idx, line in ipairs(Request.headerAll(res, "Set-Cookie")) do remember(host, line, session) end
end

---@param method string
---@param url string
---@param body string|nil
---@param content_type string|nil
---@param cb fun(res: table|nil, err: string|nil)
---@return HttpJob
local function raw(method, url, body, content_type, cb, session)
    if not loaded then Client.load() end
    session = session or active
    local host = hostOf(url)
    if host ~= READ_HOST and host ~= ACCOUNT_HOST then
        return require("source.base").defer(cb, nil, _("登录跳转地址无效"))
    end
    local headers = { Accept = "application/json, text/html;q=0.8" }
    local cookie = not session.public and Client.cookieFor(host, session) or nil
    if cookie then headers.Cookie = cookie end
    if content_type then headers["Content-Type"] = content_type end
    if host == ACCOUNT_HOST and session.csrf then
        headers["X-CSRF-Token"] = session.csrf
        headers.Referer = ACCOUNT .. "/"
    end
    if host == READ_HOST and method ~= "GET" and session.read_csrf then headers["X-CSRF-Token"] = session.read_csrf end
    return Request.request({
        url = url,
        method = method,
        body = body,
        headers = headers,
        cache_ttl = 0,
        timeout = require("http.timeout").net(0.5),
    }, function(res, err)
        if session.cancelled then return end
        if not session.public then absorb(host, res, session) end
        if res and host == READ_HOST then
            local token = Mapper.readCsrf(res.body)
            if token then session.read_csrf = token end
        end
        if err or not res then cb(nil, err and tostring(err) or _("请求失败")); return end
        cb(res)
    end)
end

--- 登录后 read.douban.com 的写请求要带首页里的 CSRF。没有就先拉一次首页。
---@param method string
---@param url string
---@param body string|nil
---@param content_type string|nil
---@param cb fun(res: table|nil, err: string|nil)
---@return HttpJob
local function send(method, url, body, content_type, cb)
    if not loaded then Client.load() end
    local session = active
    if method == "GET" or hostOf(url) ~= READ_HOST or session.read_csrf or not Client.loggedIn() then
        return raw(method, url, body, content_type, cb)
    end
    local cancelled, job = false, nil
    local handle = { cancel = function()
        cancelled = true
        if job and job.cancel then job.cancel() end
    end }
    local advanced = false
    local first = raw("GET", READ .. "/", nil, nil, function(res, err)
        advanced = true
        if cancelled then return end
        if session ~= active then cb(nil, _("登录状态已变化，请重试")); return end
        if not res or not httpOk(res.code) then cb(nil, err or _("请求失败")); return end
        if not session.read_csrf then cb(nil, _("请求失败")); return end
        job = raw(method, url, body, content_type, function(res2, err2)
            if not cancelled then cb(res2, err2) end
        end)
    end)
    if not advanced then job = first end
    return handle
end

---@param method string
---@param url string
---@param payload table|nil
---@param cb fun(wire: table|nil, err: string|nil, res: table|nil)
---@return HttpJob
local function jsonCall(method, url, payload, cb, public)
    local body, content_type
    if method ~= "GET" then
        body = payload and JSON.encode(payload) or "{}"
        content_type = "application/json"
    end
    local cookie = require("utils.settings").getSource(SOURCE_ID).cookie
    local function done(res, err)
        if not res then cb(nil, err or _("请求失败")); return end
        if not public and cookie ~= require("utils.settings").getSource(SOURCE_ID).cookie then
            cb(nil, _("登录状态已变化，请重试")); return
        end
        local reason = not public and expired(hostOf(url), res, cookie)
        if reason then cb(nil, reason, res); return end
        if not httpOk(res.code) then cb(nil, _("请求失败"), res); return end
        local ok, wire = pcall(JSON.decode, res.body or "")
        if not ok or type(wire) ~= "table" then cb(nil, _("请求失败"), res); return end
        cb(wire, nil, res)
    end
    if public then return raw(method, url, body, content_type, done, anonymous) end
    return send(method, url, body, content_type, done)
end

---@param url string
---@param hops integer
---@param cb fun(body: string|nil, err: string|nil, final_url: string|nil)
---@return HttpJob
local function follow(url, hops, cb, session)
    local cancelled, job = false, nil
    local function step(current, count)
        local advanced = false
        local next_job = raw("GET", current, nil, nil, function(res, err)
            advanced = true
            if cancelled then return end
            if not res then cb(nil, err or _("登录失败")); return end
            local code = tonumber(res.code)
            if code == 301 or code == 302 or code == 303 or code == 307 or code == 308 then
                if count >= 6 then cb(nil, _("登录失败")); return end
                local location = Request.header(res, "Location")
                if type(location) ~= "string" or location == "" then cb(nil, _("登录失败")); return end
                if location:sub(1, 2) == "//" then location = "https:" .. location
                elseif location:sub(1, 1) == "/" then location = current:match("^(https://[^/]+)") .. location end
                step(location, count + 1)
                return
            end
            if not httpOk(code) then cb(nil, _("登录失败")); return end
            cb(res.body or "", nil, current)
        end, session)
        if not advanced then job = next_job end
    end
    step(url, hops)
    return { cancel = function()
        cancelled = true
        if job then job.cancel() end
    end }
end

---@param keyword string
---@param cb fun(books: Book[]|nil, err: string|nil)
---@return HttpJob
function Client.searchAsync(keyword, cb)
    return jsonCall("POST", READ .. "/j/search_v2", Mapper.searchBody(keyword), function(wire, err)
        if not wire then cb(nil, err); return end
        cb(Mapper.searchBooks(wire))
    end, true)
end

function Client.categoriesAsync(cb)
    return raw("GET", READ .. "/category/", nil, nil, function(res, err)
        if not res or not httpOk(res.code) then cb(nil, err or _("请求失败")); return end
        cb(Mapper.categories(res.body))
    end, anonymous)
end

function Client.catalogAsync(opts, page, cb)
    return jsonCall("POST", READ .. "/j/kind/", Mapper.catalogBody(opts, page), function(wire, err)
        if not wire then cb(nil, err); return end
        local books, reason = Mapper.searchBooks(wire)
        local total = tonumber(wire.total)
        if not books or not total or total < 0 then cb(nil, reason or _("响应无效")); return end
        cb(books, nil, #wire.list == 20 and page * 20 < total)
    end, true)
end

---@param works_id string
---@param cb fun(target: table|nil, err: string|nil)
---@return HttpJob
local function accessAsync(works_id, cb, public)
    return jsonCall("POST", READ .. "/j/graphql", Mapper.worksBody(works_id, Mapper.ACCESS_HASH), function(wire, err)
        if not wire then cb(nil, err); return end
        local target = Mapper.reader(Mapper.readerUrl(wire))
        if not target then cb(nil, _("请求失败")); return end
        cb(target)
    end, public)
end

---@param works_id string
---@param cb fun(book: Book|nil, err: string|nil)
---@return HttpJob
function Client.detailAsync(works_id, cb)
    local cancelled, job = false, nil
    local advanced = false
    local first = accessAsync(works_id, function(target, err)
        advanced = true
        if cancelled then return end
        if not target then cb(nil, err); return end
        if target.kind == "column" then
            job = jsonCall("GET", READ .. "/j/column/" .. target.column_id .. "/", nil, function(wire, col_err)
                if cancelled then return end
                local row = wire and Mapper.columnBook(works_id, wire)
                if row then cb(row); return end
                cb(nil, col_err or _("请求失败"))
            end)
            return
        end
        job = jsonCall("POST", READ .. "/j/graphql", Mapper.worksBody(works_id, Mapper.INFO_HASH), function(wire, info_err)
            if cancelled then return end
            local row = wire and Mapper.infoBook(works_id, wire)
            if row then cb(row); return end
            cb(nil, info_err or _("请求失败"))
        end)
    end)
    if not advanced then job = first end
    return { cancel = function()
        cancelled = true
        if job then job.cancel() end
    end }
end

---@param aid string
---@param cb fun(article: table|nil, err: string|nil)
---@return HttpJob
function Client.articleAsync(aid, cb)
    local cached = article_cache[aid]
    if cached then return require("source.base").defer(cb, cached) end
    local user_id = Client.userId()
    local cookie = require("utils.settings").getSource(SOURCE_ID).cookie
    return send("POST", READ .. "/j/article_v2/get_reader_data", "aid=" .. Text.urlEncode(tostring(aid)),
        "application/x-www-form-urlencoded", function(res, err)
            if not res then cb(nil, err or _("请求失败")); return end
            if cookie ~= require("utils.settings").getSource(SOURCE_ID).cookie then
                cb(nil, _("登录状态已变化，请重试")); return
            end
            local reason = expired(READ_HOST, res, cookie)
            if reason then cb(nil, reason); return end
            if not httpOk(res.code) then cb(nil, _("请求失败")); return end
            local ok, wire = pcall(JSON.decode, res.body or "")
            if not ok or type(wire) ~= "table" then cb(nil, _("请求失败")); return end
            if wire.r and tonumber(wire.r) ~= 0 then
                cb(nil, type(wire.msg) == "string" and wire.msg ~= "" and wire.msg or _("请求失败"))
                return
            end
            if type(wire.data) ~= "string" or wire.data == "" then cb(nil, _("正文为空")); return end
            local article, decrypt_err = Mapper.decrypt(wire.data, user_id)
            if not article then cb(nil, decrypt_err); return end
            article_cache[tostring(aid)] = article
            cb(article)
        end)
end

---@param works_id string
---@param cb fun(chapters: BookChapter[]|nil, err: string|nil)
---@return HttpJob
function Client.tocAsync(works_id, cb)
    local cancelled, job = false, nil
    local advanced = false
    local first = accessAsync(works_id, function(target, err)
        advanced = true
        if cancelled then return end
        if not target then cb(nil, err); return end
        if target.kind == "column" then
            job = jsonCall("GET", READ .. "/j/column/" .. target.column_id .. "/", nil, function(wire, col_err)
                if cancelled then return end
                if not wire then cb(nil, col_err); return end
                cb(Mapper.columnChapters(wire))
            end)
            return
        end
        job = Client.articleAsync(target.aid, function(article, article_err)
            if cancelled then return end
            if not article then cb(nil, article_err); return end
            cb(Mapper.ebookChapters(article, target.aid))
        end)
    end)
    if not advanced then job = first end
    return { cancel = function()
        cancelled = true
        if job then job.cancel() end
    end }
end

--- 本章这些段落上的他人批注。正文段落编号用逗号拼进表单。
---@param aid string
---@param paragraph_ids string[]
---@param cb fun(rows: table|nil, err: string|nil)
---@return HttpJob|{ cancel: fun() }
function Client.annotationsAsync(aid, paragraph_ids, cb)
    if type(paragraph_ids) ~= "table" or paragraph_ids[1] == nil then
        return require("source.base").defer(cb, {})
    end
    local cookie = require("utils.settings").getSource(SOURCE_ID).cookie
    local body = "paragraph_ids=" .. Text.urlEncode(table.concat(paragraph_ids, ","))
    local url = READ .. "/j/article_v2/" .. Text.urlEncode(tostring(aid)) .. "/annotations_by_paragraphs"
    return send("POST", url, body, "application/x-www-form-urlencoded", function(res, err)
        if not res then cb(nil, err or _("请求失败")); return end
        local reason = expired(READ_HOST, res, cookie)
        if reason then cb(nil, reason); return end
        if not httpOk(res.code) then cb(nil, _("请求失败")); return end
        local ok, wire = pcall(JSON.decode, res.body or "")
        if not ok or type(wire) ~= "table" or (next(wire) ~= nil and wire[1] == nil) then
            cb(nil, _("响应无效")); return
        end
        cb(wire)
    end)
end

---@param aid string
---@param start_pid number|nil
---@param end_pid number|nil
---@param cb fun(text: string|nil, err: string|nil)
---@return HttpJob
function Client.textAsync(aid, start_pid, end_pid, cb)
    return Client.articleAsync(aid, function(article, err)
        if not article then cb(nil, err); return end
        local text = Mapper.blocksText(article, start_pid, end_pid)
        if text == "" then cb(nil, _("正文为空")); return end
        cb(text)
    end)
end

---@param cb fun(books: Book[]|nil, err: string|nil)
---@return HttpJob
function Client.shelfAsync(cb)
    if not Client.loggedIn() then return require("source.base").defer(cb, nil, _("未登录豆瓣阅读")) end
    local cancelled, job = false, nil
    local function loadWorks(ids, groups)
        job = jsonCall("POST", READ .. "/j/graphql", Mapper.shelfWorksBody(ids), function(detail, err)
            if cancelled then return end
            if not detail then cb(nil, err); return end
            cb(Mapper.shelfWorks(detail, groups, ids))
        end)
    end
    local function loadGroupDetails(ids, folder_ids)
        local advanced = false
        local pending = jsonCall("POST", READ .. "/j/graphql", {
            variables = { folderIds = folder_ids, userId = Client.userId() },
            extensions = { persistedQuery = { version = 1, sha256Hash = Mapper.SHELF_FOLDERS_HASH } },
        }, function(wire, err)
            advanced = true
            if cancelled then return end
            if not wire then cb(nil, err); return end
            local groups, group_err = Mapper.shelfGroups(wire, folder_ids)
            if not groups then cb(nil, group_err); return end
            loadWorks(ids, groups)
        end)
        if not advanced then job = pending end
    end
    local function loadGroups(ids)
        local advanced = false
        local pending = jsonCall("GET", READ .. "/j/bookshelf/folder/", nil, function(wire, err)
            advanced = true
            if cancelled then return end
            if not wire then cb(nil, err); return end
            local folder_ids, folder_err = Mapper.folderIds(wire)
            if not folder_ids then cb(nil, folder_err); return end
            if #folder_ids == 0 then loadWorks(ids, {}); return end
            loadGroupDetails(ids, folder_ids)
        end)
        if not advanced then job = pending end
    end
    local advanced = false
    local first = jsonCall("GET", READ .. "/j/bookshelf/", nil, function(wire, err)
        advanced = true
        if cancelled then return end
        if not wire then cb(nil, err); return end
        local ids, id_err = Mapper.shelfIds(wire)
        if not ids then cb(nil, id_err); return end
        if #ids == 0 then cb({}); return end
        if require("source.category_setting").enabled(SOURCE_ID) then loadGroups(ids)
        else loadWorks(ids) end
    end)
    if not advanced then job = first end
    return { cancel = function()
        cancelled = true
        if job then job.cancel() end
    end }
end

---@param works_id string
---@param method string
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return HttpJob
local function shelfWrite(works_id, method, cb)
    if not Client.loggedIn() then return require("source.base").defer(cb, nil, _("未登录豆瓣阅读")) end
    return jsonCall(method, READ .. "/j/bookshelf/", { worksIds = { tostring(works_id) } }, function(wire, err)
        if not wire then cb(nil, err or (method == "DELETE" and _("移出豆瓣阅读书架失败") or _("加入豆瓣阅读书架失败"))); return end
        cb(true)
    end)
end

function Client.addAsync(works_id, cb)
    return shelfWrite(works_id, "POST", cb)
end

function Client.removeAsync(works_id, cb)
    return shelfWrite(works_id, "DELETE", cb)
end

--- 进度和阅读时长的回包没有字段可用，2xx 就算写上了。
---@param url string
---@param body string
---@param content_type string
---@param fail string
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return HttpJob
local function write(url, body, content_type, fail, cb)
    if not Client.loggedIn() then return require("source.base").defer(cb, nil, _("未登录豆瓣阅读")) end
    local cookie = require("utils.settings").getSource(SOURCE_ID).cookie
    return send("POST", url, body, content_type, function(res, err)
        if not res then cb(nil, err or fail); return end
        local reason = expired(READ_HOST, res, cookie)
        if reason then cb(nil, reason); return end
        if not httpOk(res.code) then cb(nil, fail); return end
        if res.body and res.body ~= "" then
            local ok, wire = pcall(JSON.decode, res.body)
            if not ok or type(wire) ~= "table"
                or (wire.r ~= nil and wire.r ~= 0 and wire.r ~= false) then
                cb(nil, fail)
                return
            end
        end
        cb(true)
    end)
end

---@param works_id string
---@param cb fun(mark: { paragraph_id: string }|nil, err: string|nil)
---@return HttpJob
function Client.progressAsync(works_id, cb)
    if not Client.loggedIn() then return require("source.base").defer(cb, nil, _("未登录豆瓣阅读")) end
    return jsonCall("GET", READ .. "/j/progress/?works_id=" .. tostring(works_id), nil, function(wire, err)
        if not wire then cb(nil, err); return end
        local mark, empty = Mapper.progress(wire)
        if empty then cb(nil); return end
        if not mark then cb(nil, _("请求失败")); return end
        cb(mark)
    end)
end

--- 上传正文段落及分段索引；百分比只在整本（非专栏）时带上，和网页一致。
---@param works_id string
---@param paragraph_id string
---@param idx integer
---@param total integer
---@param with_percent boolean
---@param cb fun(ok: boolean|nil, err: string|nil)
---@param position table|nil 官网正文分段索引
---@return HttpJob
function Client.putProgressAsync(works_id, paragraph_id, idx, total, with_percent, cb, position)
    local count = total > 0 and total or 1
    local payload = {
        works_id = tonumber(works_id) or works_id,
        paragraph_id = tonumber(paragraph_id) or paragraph_id,
        paragraph_offset = 0,
        part_sequence = position and position.part_sequence or idx - 1,
        part_paragraph_sequence = position and position.part_paragraph_sequence or 0,
    }
    if with_percent then payload.percentage = math.floor((idx - 1) / count * 100) end
    return write(READ .. "/j/progress/", Text.formEncode(payload),
        "application/x-www-form-urlencoded", _("豆瓣阅读进度保存失败"), cb)
end

--- 阅读时长。网页把会话数组原样 POST 到 /j/reading_time，时间是 ISO。
---@param sessions table[]
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return HttpJob
function Client.pushReadingAsync(sessions, cb)
    return write(READ .. "/j/reading_time", JSON.encode(sessions),
        "application/json", _("豆瓣阅读阅读记录保存失败"), cb)
end

function Client.readingStatsAsync(begin_date, cb)
    if not Client.loggedIn() then return require("source.base").defer(cb, nil, _("未登录豆瓣阅读")) end
    return jsonCall("POST", READ .. "/j/graphql", {
        variables = { userId = Client.userId(), beginDate = begin_date },
        extensions = { persistedQuery = { version = 1, sha256Hash = Mapper.READING_TIME_HASH } },
    }, cb)
end

---@class DoubanLogin
---@field jars table
---@field epoch integer
---@field cancelled boolean|nil
---@field csrf string|nil
---@field read_csrf string|nil
local Login = {}
Login.__index = Login

---@param cookie string|nil
---@return DoubanLogin
function Client.newLogin(cookie)
    local session = setmetatable({ jars = {}, epoch = login_epoch }, Login)
    for pair in (cookie or ""):gmatch("[^;]+") do remember(READ_HOST, pair, session) end
    return session
end

function Login:cancel()
    self.cancelled = true
end

function Login:commit(user)
    if self.cancelled or self.epoch ~= login_epoch then return nil, _("登录状态已变化，请重试") end
    if not Client.cookieFor(READ_HOST, self) then return nil, _("登录失败") end
    local cfg = require("utils.settings").getSource(SOURCE_ID)
    if (cfg.logged_in or cfg.cookie or cfg.user_id) and cfg.user_id ~= user.id then
        local cleared = require("source.logout").clear(SOURCE_ID, function()
            cfg.cookie, cfg.user_id, cfg.name, cfg.logged_in = nil, nil, nil, nil
            require("utils.settings").saveSource(SOURCE_ID)
            Client.reset()
        end)
        if not cleared then return nil, _("清除本地记录失败") end
    end
    persist(user, self)
    return true
end

function Login:checkCookieAsync(cb)
    return follow(READ .. "/", 0, function(html, err, final_url)
        if self.cancelled or self.epoch ~= login_epoch then cb(false, _("登录状态已变化，请重试")); return end
        local user = html and hostOf(final_url) == READ_HOST and Mapper.user(html)
        if not user then cb(false, err or _("登录失败")); return end
        cb(true, nil, user)
    end, self)
end

---@param cb fun(authorize: string|nil, err: string|nil)
---@return HttpJob
function Login:beginAsync(cb)
    return follow(LOGIN_URL, 0, function(html, err, authorize)
        if not html then cb(nil, err or _("登录失败")); return end
        self.csrf = Mapper.csrf(html)
        if not self.csrf or hostOf(authorize) ~= ACCOUNT_HOST then cb(nil, _("登录失败")); return end
        self.authorize = authorize
        cb(authorize)
    end, self)
end

local function accountResponse(res, err)
    if not res then return nil, err or _("请求失败") end
    local ok, wire = pcall(JSON.decode, res.body or "")
    if not httpOk(res.code) then
        if ok and type(wire) == "table" and type(wire.message) == "string" and wire.message ~= "" then
            return nil, wire.message
        end
        return nil, _("请求失败")
    end
    if not ok or type(wire) ~= "table" then return nil, _("响应无效") end
    return wire
end

---@param phone string 国际区号与手机号，例如 +86…
---@param cb fun(retry_after: number|nil, err: string|nil)
---@return HttpJob
function Login:sendPhoneCodeAsync(phone, cb)
    return raw("POST", ACCOUNT .. "/oidc/phone/verify_code", JSON.encode({ phone_number = phone }),
        "application/json", function(res, err)
            local wire, reason = accountResponse(res, err)
            if not wire then cb(nil, reason); return end
            if not (type(wire.retry_after) == "number" and wire.retry_after >= 0 and wire.retry_after < math.huge) then
                cb(nil, _("响应无效")); return
            end
            cb(wire.retry_after)
        end, self)
end

---@param phone string
---@param code string
---@param cb fun(user: table|nil, err: string|nil)
---@return HttpJob
function Login:verifyPhoneAsync(phone, code, cb)
    local cancelled, job, advanced = false, nil, false
    local first = raw("POST", ACCOUNT .. "/oidc/phone/verify", JSON.encode({ phone_number = phone, code = code }),
        "application/json", function(res, err)
            advanced = true
            if cancelled then return end
            local wire, reason = accountResponse(res, err)
            if not wire then cb(nil, reason); return end
            if type(wire.transfer_info) == "table" then
                cb(nil, _("此账号需要在豆瓣阅读官网确认历史数据授权，完成后再登录")); return
            end
            job = self:finishQrAsync(self.authorize, function(user, finish_err)
                if not cancelled then cb(user, finish_err) end
            end)
        end, self)
    if not advanced then job = first end
    return { cancel = function()
        cancelled = true
        if job then job.cancel() end
    end }
end

---@param cb fun(ticket: { qr: string, code: string, authorize: string, expires_in: number }|nil, err: string|nil)
---@return HttpJob
function Login:beginQrAsync(cb)
    local cancelled, job = false, nil
    local advanced = false
    local first = self:beginAsync(function(authorize, err)
        advanced = true
        if cancelled then return end
        if not authorize then cb(nil, err or _("获取二维码失败")); return end
        job = raw("POST", ACCOUNT .. "/oidc/qrcode/generate", nil, "application/json", function(res, gen_err)
            if cancelled then return end
            if not res or not httpOk(res.code) then cb(nil, gen_err or _("获取二维码失败")); return end
            local decoded, wire = pcall(JSON.decode, res.body or "")
            if not decoded then cb(nil, _("获取二维码失败")); return end
            local ticket = wire and Mapper.qr(wire, ACCOUNT)
            if not ticket or type(authorize) ~= "string" then cb(nil, gen_err or _("获取二维码失败")); return end
            cb({ qr = ticket.qr, code = ticket.code, authorize = authorize, expires_in = ticket.expires_in })
        end, self)
    end)
    if not advanced then job = first end
    return { cancel = function()
        cancelled = true
        if job then job.cancel() end
    end }
end

---@param code string
---@param cb fun(kind: string|nil, err: string|nil)
---@return HttpJob
function Login:qrStatusAsync(code, cb)
    return raw("POST", ACCOUNT .. "/oidc/qrcode/status", JSON.encode({ code = code }), "application/json", function(res, err)
        if not res or not httpOk(res.code) then cb(nil, err or _("登录失败")); return end
        local decoded, wire = pcall(JSON.decode, res.body or "")
        local kind = decoded and Mapper.qrStatus(wire)
        if not kind then cb(nil, _("登录失败")); return end
        cb(kind)
    end, self)
end

---@param authorize string
---@param cb fun(user: { id: string, name: string }|nil, err: string|nil)
---@return HttpJob
function Login:finishQrAsync(authorize, cb)
    local cancelled, job = false, nil
    local advanced = false
    local first = follow(authorize, 0, function(html, err, final_url)
        advanced = true
        if cancelled then return end
        if not html then cb(nil, err or _("登录失败")); return end
        local user = Mapper.user(html)
        if user and hostOf(final_url) == READ_HOST then
            local ok, reason = self:commit(user)
            cb(ok and user or nil, reason)
            return
        end
        if hostOf(final_url) == READ_HOST then cb(nil, _("登录失败")); return end
        job = follow(READ .. "/", 0, function(home, home_err)
            if cancelled then return end
            user = home and Mapper.user(home)
            if not user then cb(nil, home_err or _("登录失败")); return end
            local ok, reason = self:commit(user)
            cb(ok and user or nil, reason)
        end, self)
    end, self)
    if not advanced then job = first end
    return { cancel = function()
        cancelled = true
        if job then job.cancel() end
    end }
end

---@param works_id string
---@param chapter_id string|nil
---@param offset integer
---@param cb fun(page: table|nil, err: string|nil)
---@return HttpJob
function Client.communityAsync(works_id, chapter_id, offset, cb)
    if offset > 0 and not Client.loggedIn() then
        return require("source.base").defer(cb, nil, _("请先登录豆瓣阅读"))
    end
    local cancelled, job, pending = false, nil, true
    local function fetch(column_id)
        local body = Mapper.worksBody(works_id,
            "sha256:ec47b1cca2876392e72ca83dd4d59b12e2e27b72366d2c1b7a8e9ff672f4bb7c")
        if chapter_id then
            body.extensions.persistedQuery.sha256Hash =
                "sha256:161b3ceea6f04246919461367c6c071d62020836125a9ba6c42022295717a30a"
            body.variables.worksId = nil
            body.variables.columnId = column_id
            body.variables.chapterId = chapter_id
        end
        body.variables.start, body.variables.limit = offset, 20
        body.variables.sort, body.variables.isAdmin = "TIME_DESC", false
        return jsonCall("POST", READ .. "/j/graphql", body, function(wire, err)
            if cancelled then return end
            if not wire then cb(nil, err); return end
            cb(Mapper.communityPage(wire, offset, chapter_id))
        end, offset == 0)
    end
    if not chapter_id then return fetch() end
    local first = accessAsync(works_id, function(target, err)
        pending = false
        if cancelled then return end
        if not target then cb(nil, err); return end
        if target.kind ~= "column" then
            cb({ items = {}, total = 0, more = false, max_idx = offset, unsupported = true })
            return
        end
        job = fetch(target.column_id)
    end, true)
    if pending then job = first end
    return { cancel = function()
        cancelled = true
        if job then job.cancel() end
    end }
end

return Client
