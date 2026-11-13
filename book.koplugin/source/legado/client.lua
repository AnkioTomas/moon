--[[--
阅读（Legado）Web 服务 HTTP 客户端（仅异步）。

三种后端共用回包 `{ isSuccess, errorMsg, data }` 与 0 基章节 `index`，按地址后缀区分（Client.mode）：
- app：阅读 App 的 Web 服务（http://192.168.1.8:1122），GET 查询、JSON 上报；
- reader3：服务器版（…/reader3），可登录；书架 GET，其余 POST JSON；
- qread：轻阅读（…/api/5），可登录；全部 POST 表单，章节 / 正文要带书源 origin。

@module koplugin.book.source.legado.client
--]]

local JSON = require("json")
local Request = require("http.request")
local Text = require("utils.text")
local _ = require("l10n").get("source.legado")

local Client = {}

local SOURCE_ID = "legado"

--- 服务器地址，缺协议头按 http 补；没配置返回 nil。
---@param cfg table|nil 校验待保存配置时显式传入，不改变当前库
---@return string|nil
function Client.base(cfg)
    local addr = (cfg or require("utils.settings").getSource(SOURCE_ID)).server_address
    if type(addr) ~= "string" or addr == "" then return nil end
    if not addr:match("^https?://") then addr = "http://" .. addr end
    return (addr:gsub("/+$", ""))
end

--- 解回包：isSuccess 为真才算成功，返回 data。
---@param raw string|nil
---@param err any
---@return any|nil data, string|nil err
function Client.decode(raw, err)
    if not raw then return nil, err and tostring(err) or _("请求失败") end
    local ok, wire = pcall(JSON.decode, raw)
    if not ok or type(wire) ~= "table" then return nil, _("响应无效") end
    if not wire.isSuccess then return nil, wire.errorMsg ~= "" and wire.errorMsg or _("请求失败") end
    if wire.data == nil then return {} end
    return wire.data
end

---@alias LegadoMode "app"|"reader3"|"qread"

--- 后端类型，看地址路径的最后一段。
---@param cfg table|nil
---@return LegadoMode
function Client.mode(cfg)
    local base = Client.base(cfg) or ""
    if base:find("/reader3$") then return "reader3" end
    if base:find("/api/%d+$") then return "qread" end
    return "app"
end

--- 服务根（去掉 /reader3、/api/N），封面与书内图片的相对路径从这里起算。
---@return string
local function root()
    return ((Client.base() or ""):gsub("/reader3$", ""):gsub("/api/%d+$", ""))
end

---@param path string
---@param query table<string, any>|nil
---@param cfg table|nil
---@return string|nil
local function url(path, query, cfg)
    local base = Client.base(cfg)
    if not base then return nil end
    local out = base .. path
    if query then
        local qs = Text.formEncode(query)
        if qs ~= "" then out = out .. "?" .. qs end
    end
    return out
end

--- 账号密码（阅读 App 的 Web 服务没有账号）；缺一项视为无需登录。
---@param cfg table|nil
---@return string|nil user, string|nil password
local function credentials(cfg)
    cfg = cfg or require("utils.settings").getSource(SOURCE_ID)
    if type(cfg.username) == "string" and cfg.username ~= "" and type(cfg.password) == "string" and cfg.password ~= "" then
        return cfg.username, cfg.password
    end
    return nil
end

-- accessToken 只在内存里，key 带地址与账号，改了配置自然作废。
local session = { key = nil, token = nil }

---@param method "GET"|"POST"
---@param enc "json"|"form"|nil POST 体编码
---@param target string
---@param body table|nil
---@param ratio number
---@param done fun(data: any|nil, err: string|nil)
---@return { cancel: fun() }
local function send(method, enc, target, body, ratio, done)
    local opts = { accept = "application/json", timeout = require("http.timeout").net(ratio) }
    local function finish(raw, err) done(Client.decode(raw, err)) end
    if method == "GET" then return Request.get(target, opts, finish) end
    if enc == "form" then
        opts.content_type = "application/x-www-form-urlencoded"
        local flat = {}
        for k, v in pairs(body) do
            if type(v) ~= "table" then flat[k] = v end
        end
        return Request.post(target, Text.formEncode(flat), opts, finish)
    end
    opts.content_type = "application/json"
    return Request.post(target, JSON.encode(body), opts, finish)
end

---@param user string
---@param password string
---@param cb fun(token: string|nil, err: string|nil)
---@param cfg table|nil
---@return { cancel: fun() }
local function login(user, password, cb, cfg)
    local target = url("/login", nil, cfg)
    if not target then return require("source.base").defer(cb, nil, _("未配置阅读服务器地址")) end
    local qread = Client.mode(cfg) == "qread"
    local body = qread and { username = user, password = password, model = "web" }
        or { username = user, password = password, code = "", isLogin = true, v = os.time() }
    return send("POST", qread and "form" or "json", target, body, 0.5, function(data, reason)
        local token = type(data) == "table" and data.accessToken
        if type(token) ~= "string" or token == "" then
            cb(nil, reason or _("登录失败"))
            return
        end
        cb(token)
    end)
end

--- 配了账号密码时先登录、请求带 accessToken；服务端回 NEED_LOGIN（令牌过期）就重新登录再试一次。
--- 重登仍失败 / 仍 NEED_LOGIN → Auth.expire，引导用户检查账号密码。
---@param go fun(token: string|nil, done: fun(data: any|nil, err: string|nil)): { cancel: fun() }
---@param cb fun(data: any|nil, err: string|nil)
---@param cfg table|nil
---@return { cancel: fun() }
local function authed(go, cb, cfg)
    local user, password = credentials(cfg)
    if not user then return go(nil, cb) end
    local auth_session = cfg and {} or session
    local key = Client.base(cfg) .. "\0" .. user .. "\0" .. password
    local expired_msg = _("打开「设置 → 书库 → 账号 → 开源阅读 → 阅读服务地址」。账号和密码重新填一遍，地址不用改，点「保存」。阅读 App 里如果改过密码，这里填新密码。")
    ---@type boolean, CancelHandle|nil
    local cancelled, job = false, nil
    local function run(retry)
        local function call(token)
            job = go(token, function(data, err)
                if cancelled then return end
                if retry and err and err:find("NEED_LOGIN", 1, true) then
                    auth_session.token = nil
                    run(false)
                    return
                end
                if err and err:find("NEED_LOGIN", 1, true) then
                    err = require("source.auth").expire(SOURCE_ID, expired_msg)
                end
                cb(data, err)
            end)
        end
        if auth_session.key == key and auth_session.token then
            call(auth_session.token)
        else
            job = login(user, password, function(token, err)
                if cancelled then return end
                if not token then
                    -- 令牌过期后的重登失败：明确通知；首次配置错误登录仍原样返回。
                    if not retry then
                        err = require("source.auth").expire(SOURCE_ID, expired_msg)
                    end
                    cb(nil, err)
                    return
                end
                auth_session.key, auth_session.token = key, token
                require("source.auth").ok(SOURCE_ID)
                call(token)
            end, cfg)
        end
    end
    run(true)
    return { cancel = function()
        cancelled = true
        job.cancel()
    end }
end

--- 一次调用。kind：shelf（app / reader3 用 GET）、read（只有 app 用 GET）、write；其余按后端走 POST JSON / 表单。
---@param path string
---@param params table<string, any>
---@param ratio number 超时倍率
---@param kind "shelf"|"read"|"write"
---@param cb fun(data: any|nil, err: string|nil)
---@param cfg table|nil
---@return { cancel: fun() }
local function call(path, params, ratio, kind, cb, cfg)
    local mode = Client.mode(cfg)
    local get = (kind == "shelf" and mode ~= "qread") or (kind == "read" and mode == "app")
    local method = get and "GET" or "POST"
    return authed(function(token, done)
        local query = token and { accessToken = token } or nil
        if method == "GET" then
            query = query or {}
            for k, v in pairs(params) do query[k] = v end
        end
        local target = url(path, query, cfg)
        if not target then return require("source.base").defer(done, nil, _("未配置阅读服务器地址")) end
        return send(method, mode == "qread" and "form" or "json", target, params, ratio, done)
    end, cb, cfg)
end

--- 书内图片地址：服务端给的相对路径补成可直接下载的 URL（app 的相对路径没有意义，原样返回）。
---@param src string
---@param base string|nil EPUB 章节 URL，按它解析相对引用；只给同服务器的资源带令牌。
---@return string
function Client.imageUrl(src, base)
    local out
    if base then
        out = assert(Text.absoluteUrl(base, src), "invalid chapter resource URL")
        if out:match("^(https?://[^/]+)") ~= root():match("^(https?://[^/]+)") then return out end
    else
        if src:find("^https?://") then return src end
        local mode = Client.mode()
        if mode == "app" then return src end
        if mode == "qread" then
            out = src:find("^baseurl/") and (Client.base() .. src:sub(8))
                or (Client.base() .. "/proxypng?url=" .. Text.urlEncode(src))
        else
            out = root() .. src:gsub("^__API_ROOT__", "")
        end
    end
    if session.token then
        local target, fragment = out:match("^([^#]*)(.*)$")
        out = target .. (target:find("?", 1, true) and "&" or "?") .. "accessToken=" .. session.token .. fragment
    end
    return out
end

--- 封面地址。阅读 App 的原地址常要 Referer / 本地路径，一律走 /cover 代理。
---@param path string
---@return string
function Client.coverUrl(path)
    if Client.mode() == "app" then return url("/cover", { path = path }) end
    return Client.imageUrl(path)
end

---@param cb fun(rows: table[]|nil, err: string|nil)
---@param cfg table|nil 待保存配置；缺省读取当前配置
---@return { cancel: fun() }
function Client.shelfAsync(cb, cfg)
    local params = { app = { refresh = 0 }, reader3 = { refresh = 0 }, qread = { version = "3.2.1" } }
    return call("/getBookshelf", params[Client.mode(cfg)], 0.5, "shelf", function(data, err)
        if type(data) ~= "table" then cb(nil, err); return end
        cb(data)
    end, cfg)
end

--- 目录。book_url + 书源（轻阅读必需，其余忽略）。
---@param book_url string
---@param origin string|nil
---@param cb fun(rows: table[]|nil, err: string|nil)
---@return { cancel: fun() }
function Client.chaptersAsync(book_url, origin, cb)
    return call("/getChapterList", { url = book_url, bookSourceUrl = origin }, 1, "read", function(data, err)
        if type(data) ~= "table" then cb(nil, err); return end
        cb(data)
    end)
end

--- 一章正文（0 基序号），纯文本；轻阅读回包是 `{ text }`。
---@param book_url string
---@param index integer
---@param origin string|nil
---@param cb fun(text: string|nil, err: string|nil)
---@return { cancel: fun() }
function Client.contentAsync(book_url, index, origin, cb)
    local params = { url = book_url, index = index, bookSourceUrl = origin, type = origin and 0 or nil }
    return call("/getBookContent", params, 1, "read", function(data, err)
        local text = type(data) == "table" and data.text or data
        if type(text) ~= "string" or text == "" then
            require("utils.log").warn("legado empty chapter", book_url, index, type(text), err)
            cb(nil, err or (_("阅读章节内容为空") .. " #" .. (index + 1)))
            return
        end
        cb(text)
    end)
end

local function reviewCall(path, params, cb)
    if Client.mode() ~= "app" then
        return require("source.base").defer(cb, nil, _("段评仅支持阅读 App 的 Web 服务"))
    end
    return call(path, params, 1, "read", cb)
end

---@param book_url string
---@param index integer 阅读目录里的 0 基序号
---@param cb function
---@return { cancel: fun() }
function Client.reviewSummaryAsync(book_url, index, cb)
    return reviewCall("/getReviewSummary", { url = book_url, index = index }, cb)
end

---@param book_url string
---@param index integer
---@param paragraph integer
---@param data string
---@param page integer
---@param cursor string|nil
---@param cb function
---@return { cancel: fun() }
function Client.reviewDetailAsync(book_url, index, paragraph, data, page, cursor, cb)
    return reviewCall("/getReviewDetail", {
        url = book_url, index = index, paraIndex = paragraph, paraData = data, page = page, cursor = cursor,
    }, cb)
end

---@param book_url string
---@param index integer
---@param paragraph integer
---@param data string
---@param review_id string
---@param page integer
---@param cb function
---@return { cancel: fun() }
function Client.reviewRepliesAsync(book_url, index, paragraph, data, review_id, page, cb)
    return reviewCall("/getReviewReplies", {
        url = book_url, index = index, paraIndex = paragraph, paraData = data, reviewId = review_id, page = page,
    }, cb)
end

--- 上报阅读位置。row 是书架原行（name / author / bookUrl / origin）。
---@param row table
---@param pos { index: integer, title: string|nil, offset: integer }
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }
function Client.saveProgressAsync(row, pos, cb)
    local body = {
        name = row.name,
        author = row.author,
        url = row.bookUrl,
        index = pos.index,
        durChapterIndex = pos.index,
        durChapterPos = pos.offset,
        durChapterTitle = pos.title or "",
        durChapterTime = os.time() * 1000,
    }
    if Client.mode() == "qread" then
        body = { url = row.bookUrl, index = pos.index, title = pos.title or "", pos = pos.offset }
    end
    return call("/saveBookProgress", body, 0.5, "write", function(_data, reason) cb(reason == nil or nil, reason) end)
end

--- 把书从阅读 App 书架移除，row 是书架原行。
---@param row table
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }
function Client.deleteBookAsync(row, cb)
    return call("/deleteBook", row, 0.5, "write", function(_data, reason) cb(reason == nil or nil, reason) end)
end

return Client
