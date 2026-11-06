--[[--
豆瓣阅读网页接口。

搜索、专栏目录和免费章节不登录也能读。正文密钥在匿名时是 SHA-256("anonymous")。
登录是豆瓣阅读 App 扫码：先跟到 accounts.arkread.com 的授权页，再轮询二维码。
扫码成功后授权页跳回 read.douban.com，会话是 Set-Cookie，解密密钥换成用户编号。

@module source.douban.client
--]]

require("l10n").apply()
local JSON = require("json")
local Mapper = require("source.douban.mapper")
local Request = require("http.request")
local _ = require("gettext")

local Client = {}

local SOURCE_ID = "douban"
local READ_HOST = "read.douban.com"
local ACCOUNT_HOST = "accounts.arkread.com"
local READ = "https://" .. READ_HOST
local ACCOUNT = "https://" .. ACCOUNT_HOST
local LOGIN_URL = READ .. "/oidc/login?redir=https%3A%2F%2Fread.douban.com%2F"
local LOGIN_EXPIRED = "豆瓣阅读登录已失效，请点「重新登录」，用豆瓣阅读 App 扫码。"

local jars = {}
local csrf_token
local read_csrf
local article_cache = {}
local loaded = false

local function remember(host, header)
    if type(host) ~= "string" or type(header) ~= "string" or header == "" then return end
    local jar = jars[host] or {}
    jars[host] = jar
    for part in header:gmatch("[^;]+") do
        local name, value = part:match("^%s*([^=;%s]+)=([^%s].*)$")
        if not name then name, value = part:match("^%s*([^=;%s]+)=(.*)$") end
        if name and value and name ~= "Path" and name ~= "Domain" and name ~= "Expires"
            and name ~= "Max-Age" and name ~= "SameSite" then
            jar[name] = value
        end
    end
end

function Client.reset()
    jars = {}
    csrf_token = nil
    read_csrf = nil
    article_cache = {}
    loaded = false
end

function Client.load()
    jars = {}
    csrf_token = nil
    read_csrf = nil
    remember(READ_HOST, require("utils.settings").getSource(SOURCE_ID).cookie)
    loaded = true
end

---@param host string
---@return string|nil
function Client.cookieFor(host)
    local jar = jars[host]
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
function Client.persist(user)
    local settings = require("utils.settings")
    local cfg = settings.getSource(SOURCE_ID)
    cfg.cookie = Client.cookieFor(READ_HOST)
    cfg.user_id = user.id
    cfg.name = user.name
    cfg.logged_in = true
    settings.saveSource(SOURCE_ID)
    article_cache = {}
end

---@param url string
---@return string
local function hostOf(url)
    return url:match("^https://([^/]+)") or READ_HOST
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
local function expired(host, res)
    if host == READ_HOST and tonumber(res and res.code) == 401
        and require("utils.settings").getSource(SOURCE_ID).logged_in == true then
        return require("source.auth").expire(SOURCE_ID, _(LOGIN_EXPIRED))
    end
    return nil
end

---@param res table|nil
local function absorb(host, res)
    if not res then return end
    for _idx, line in ipairs(Request.headerAll(res, "Set-Cookie")) do remember(host, line) end
end

---@param method string
---@param url string
---@param body string|nil
---@param content_type string|nil
---@param cb fun(res: table|nil, err: string|nil)
---@return HttpJob
local function raw(method, url, body, content_type, cb)
    if not loaded then Client.load() end
    local host = hostOf(url)
    local headers = { Accept = "application/json, text/html;q=0.8" }
    local cookie = Client.cookieFor(host)
    if cookie then headers.Cookie = cookie end
    if content_type then headers["Content-Type"] = content_type end
    if host == ACCOUNT_HOST and csrf_token then headers["X-CSRF-Token"] = csrf_token end
    if host == READ_HOST and method ~= "GET" and read_csrf then headers["X-CSRF-Token"] = read_csrf end
    return Request.request({
        url = url,
        method = method,
        body = body,
        headers = headers,
        timeout = require("http.timeout").net(0.5),
    }, function(res, err)
        absorb(host, res)
        if res and host == READ_HOST then
            local token = Mapper.readCsrf(res.body)
            if token then read_csrf = token end
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
    if method == "GET" or hostOf(url) ~= READ_HOST or read_csrf or not Client.loggedIn() then
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
        if not res or not httpOk(res.code) then cb(nil, err or _("请求失败")); return end
        if not read_csrf then cb(nil, _("请求失败")); return end
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
local function jsonCall(method, url, payload, cb)
    local body, content_type
    if method ~= "GET" then
        body = payload and JSON.encode(payload) or "{}"
        content_type = "application/json"
    end
    return send(method, url, body, content_type, function(res, err)
        if not res then cb(nil, err or _("请求失败")); return end
        local reason = expired(hostOf(url), res)
        if reason then cb(nil, reason, res); return end
        if not httpOk(res.code) then cb(nil, _("请求失败"), res); return end
        local ok, wire = pcall(JSON.decode, res.body or "")
        if not ok or type(wire) ~= "table" then cb(nil, _("请求失败"), res); return end
        cb(wire, nil, res)
    end)
end

---@param url string
---@param hops integer
---@param cb fun(body: string|nil, err: string|nil, final_url: string|nil)
---@return HttpJob
local function follow(url, hops, cb)
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
                if location:sub(1, 1) == "/" then location = current:match("^(https://[^/]+)") .. location end
                step(location, count + 1)
                return
            end
            if not httpOk(code) then cb(nil, _("登录失败")); return end
            cb(res.body or "", nil, current)
        end)
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
    end)
end

---@param works_id string
---@param cb fun(target: table|nil, err: string|nil)
---@return HttpJob
local function accessAsync(works_id, cb)
    return jsonCall("POST", READ .. "/j/graphql", Mapper.worksBody(works_id, Mapper.ACCESS_HASH), function(wire, err)
        if not wire then cb(nil, err); return end
        local target = Mapper.reader(Mapper.readerUrl(wire))
        if not target then cb(nil, _("请求失败")); return end
        cb(target)
    end)
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
    return send("POST", READ .. "/j/article_v2/get_reader_data", "aid=" .. aid,
        "application/x-www-form-urlencoded", function(res, err)
            if not res then cb(nil, err or _("请求失败")); return end
            local reason = expired(READ_HOST, res)
            if reason then cb(nil, reason); return end
            if not httpOk(res.code) then cb(nil, _("请求失败")); return end
            local ok, wire = pcall(JSON.decode, res.body or "")
            if not ok or type(wire) ~= "table" then cb(nil, _("请求失败")); return end
            if wire.r and tonumber(wire.r) ~= 0 then
                cb(nil, type(wire.msg) == "string" and wire.msg ~= "" and wire.msg or _("请求失败"))
                return
            end
            if type(wire.data) ~= "string" or wire.data == "" then cb(nil, _("正文为空")); return end
            local article, decrypt_err = Mapper.decrypt(wire.data, Client.userId())
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
    local Text = require("utils.text")
    local body = "paragraph_ids=" .. Text.urlEncode(table.concat(paragraph_ids, ","))
    local url = READ .. "/j/article_v2/" .. Text.urlEncode(tostring(aid)) .. "/annotations_by_paragraphs"
    return send("POST", url, body, "application/x-www-form-urlencoded", function(res, err)
        if not res then cb(nil, err or _("请求失败")); return end
        local reason = expired(READ_HOST, res)
        if reason then cb(nil, reason); return end
        if not httpOk(res.code) then cb(nil, _("请求失败")); return end
        local ok, wire = pcall(JSON.decode, res.body or "")
        if not ok or type(wire) ~= "table" then cb(nil, _("请求失败")); return end
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
    local advanced = false
    local first = jsonCall("GET", READ .. "/j/bookshelf/", nil, function(wire, err)
        advanced = true
        if cancelled then return end
        if not wire then cb(nil, err); return end
        local ids, id_err = Mapper.shelfIds(wire)
        if not ids then cb(nil, id_err); return end
        if #ids == 0 then cb({}); return end
        job = jsonCall("POST", READ .. "/j/graphql", Mapper.shelfWorksBody(ids), function(detail, detail_err)
            if cancelled then return end
            if not detail then cb(nil, detail_err); return end
            cb(Mapper.shelfWorks(detail))
        end)
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
---@param fail string
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return HttpJob
local function writeJson(url, body, fail, cb)
    if not Client.loggedIn() then return require("source.base").defer(cb, nil, _("未登录豆瓣阅读")) end
    return send("POST", url, body, "application/json", function(res, err)
        if not res then cb(nil, err or fail); return end
        local reason = expired(READ_HOST, res)
        if reason then cb(nil, reason); return end
        if not httpOk(res.code) then cb(nil, fail); return end
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

--- 电子书的 paragraph_id 是目录段落。百分比只在整本（非专栏）时带上，和网页一致。
---@param works_id string
---@param paragraph_id string
---@param idx integer
---@param total integer
---@param with_percent boolean
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return HttpJob
function Client.putProgressAsync(works_id, paragraph_id, idx, total, with_percent, cb)
    local count = total > 0 and total or 1
    local payload = {
        works_id = tonumber(works_id) or works_id,
        paragraph_id = tonumber(paragraph_id) or paragraph_id,
        paragraph_offset = 0,
        part_sequence = idx - 1,
        part_paragraph_sequence = 0,
    }
    if with_percent then payload.percentage = math.floor(idx / count * 100 + 0.5) end
    return writeJson(READ .. "/j/progress/", JSON.encode(payload), _("豆瓣阅读进度保存失败"), cb)
end

--- 阅读时长。网页把会话数组原样 POST 到 /j/reading_time，时间是 ISO。
---@param sessions table[]
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return HttpJob
function Client.pushReadingAsync(sessions, cb)
    return writeJson(READ .. "/j/reading_time", JSON.encode(sessions), _("豆瓣阅读阅读记录保存失败"), cb)
end

---@param cb fun(ticket: { qr: string, code: string, authorize: string }|nil, err: string|nil)
---@return HttpJob
function Client.beginQrAsync(cb)
    Client.load()
    csrf_token = nil
    local cancelled, job = false, nil
    local advanced = false
    local first = follow(LOGIN_URL, 0, function(html, err, authorize)
        advanced = true
        if cancelled then return end
        if not html then cb(nil, err or _("获取二维码失败")); return end
        csrf_token = Mapper.csrf(html)
        if not csrf_token then cb(nil, _("获取二维码失败")); return end
        job = raw("POST", ACCOUNT .. "/oidc/qrcode/generate", nil, "application/json", function(res, gen_err)
            if cancelled then return end
            if not res or not httpOk(res.code) then cb(nil, gen_err or _("获取二维码失败")); return end
            local decoded, wire = pcall(JSON.decode, res.body or "")
            if not decoded then cb(nil, _("获取二维码失败")); return end
            local ticket = wire and Mapper.qr(wire, ACCOUNT)
            if not ticket or type(authorize) ~= "string" then cb(nil, gen_err or _("获取二维码失败")); return end
            cb({ qr = ticket.qr, code = ticket.code, authorize = authorize })
        end)
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
function Client.qrStatusAsync(code, cb)
    return jsonCall("POST", ACCOUNT .. "/oidc/qrcode/status", { code = code }, function(wire, err)
        local kind = wire and Mapper.qrStatus(wire)
        if not kind then cb(nil, err or _("登录失败")); return end
        cb(kind)
    end)
end

---@param authorize string
---@param cb fun(user: { id: string, name: string }|nil, err: string|nil)
---@return HttpJob
function Client.finishQrAsync(authorize, cb)
    local cancelled, job = false, nil
    local advanced = false
    local first = follow(authorize, 0, function(html, err, final_url)
        advanced = true
        if cancelled then return end
        if not html then cb(nil, err or _("登录失败")); return end
        local user = Mapper.user(html)
        if user then Client.persist(user); cb(user); return end
        if type(final_url) == "string" and final_url:find(READ_HOST, 1, true) then cb(nil, _("登录失败")); return end
        job = follow(READ .. "/", 0, function(home, home_err)
            if cancelled then return end
            user = home and Mapper.user(home)
            if not user then cb(nil, home_err or _("登录失败")); return end
            Client.persist(user)
            cb(user)
        end)
    end)
    if not advanced then job = first end
    return { cancel = function()
        cancelled = true
        if job then job.cancel() end
    end }
end

return Client
