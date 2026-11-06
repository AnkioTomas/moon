--[[--
网易云阅读网页接口。

搜索、榜单、目录和免费章节不登录。未购买章节返回 code -1。
登录页没有扫码：密码直接提交，短信要先过图形验证码。
阅读位置上报用登录后的 csrf。书架列表还没见过，这里不加、不删。

@module source.netease.client
--]]

require("l10n").apply()
local JSON = require("json")
local Mapper = require("source.netease.mapper")
local Request = require("http.request")
local Text = require("utils.text")
local _ = require("gettext")

local Client = {}

local HOST = "https://yuedu.3g.163.com"
local SOURCE_ID = "netease"
local jar = {}
local csrf_token

local RANK = {
    male = "/rank/original/list/data.json?gender=male&sortType=day&type=sell",
    female = "/rank/original/list/data.json?gender=female&sortType=day&type=sell",
    publish = "/rank/publish/list/data.json?sortType=day&type=sell",
}

local function remember(header)
    if type(header) ~= "string" or header == "" then return end
    for part in header:gmatch("[^;]+") do
        local name, value = part:match("^%s*([^=;%s]+)=([^%s].*)$")
        if not name then name, value = part:match("^%s*([^=;%s]+)=(.*)$") end
        if name and value and value ~= "" and value ~= '""' then
            local lower = name:lower()
            if lower ~= "path" and lower ~= "domain" and lower ~= "expires"
                and lower ~= "max-age" and lower ~= "samesite" then
                jar[name] = value
            end
        end
    end
end

function Client.reset()
    jar = {}
    csrf_token = nil
end

function Client.load()
    Client.reset()
    local cfg = require("utils.settings").getSource(SOURCE_ID)
    remember(cfg.cookie)
    if type(cfg.csrf) == "string" and cfg.csrf ~= "" then csrf_token = cfg.csrf end
end

---@return string|nil
function Client.cookie()
    local names = {}
    for name in pairs(jar) do names[#names + 1] = name end
    table.sort(names)
    if #names == 0 then return nil end
    local parts = {}
    for _idx, name in ipairs(names) do parts[#parts + 1] = name .. "=" .. jar[name] end
    return table.concat(parts, "; ")
end

function Client.persist()
    local settings = require("utils.settings")
    local cfg = settings.getSource(SOURCE_ID)
    cfg.cookie = Client.cookie()
    cfg.csrf = csrf_token
    settings.saveSource(SOURCE_ID)
end

---@return boolean
function Client.loggedIn()
    Client.load()
    local cfg = require("utils.settings").getSource(SOURCE_ID)
    return cfg.logged_in == true and Client.cookie() ~= nil
        and type(csrf_token) == "string" and csrf_token ~= ""
end

---@param res table|nil
---@return boolean
local function absorb(res)
    if not res then return false end
    local lines = Request.headerAll(res, "Set-Cookie")
    if #lines == 0 then return false end
    for _idx, line in ipairs(lines) do remember(line) end
    return true
end

---@return table
local function opts()
    local out = { timeout = require("http.timeout").net(0.5) }
    local cookie = Client.cookie()
    if cookie then out.headers = { Cookie = cookie } end
    return out
end

---@param url string
---@param cb fun(wire: table|nil, err: string|nil)
---@return HttpJob
local function getJson(url, cb)
    Client.load()
    return Request.get(url, opts(), function(raw, err, res)
        if absorb(res) and require("utils.settings").getSource(SOURCE_ID).logged_in == true then
            Client.persist()
        end
        if not raw or raw == "" then cb(nil, err and tostring(err) or _("请求失败")); return end
        local ok, wire = pcall(JSON.decode, raw)
        if not ok or type(wire) ~= "table" then cb(nil, _("请求失败")); return end
        cb(wire)
    end)
end

---@param keyword string
---@param cb fun(books: Book[]|nil, err: string|nil)
---@return HttpJob
function Client.searchAsync(keyword, cb)
    local url = HOST .. "/search/book/data.json?key=" .. Text.urlEncode(keyword)
    return getJson(url, function(wire, err)
        if not wire then cb(nil, err); return end
        cb(Mapper.searchBooks(wire))
    end)
end

---@param node string|nil
---@param cb fun(books: Book[]|nil, err: string|nil)
---@return HttpJob
function Client.rankAsync(node, cb)
    local path = RANK[node] or RANK.male
    return getJson(HOST .. path, function(wire, err)
        if not wire then cb(nil, err); return end
        cb(Mapper.searchBooks(wire))
    end)
end

---@param stable_id string
---@param cb fun(wire: table|nil, err: string|nil)
---@return HttpJob
function Client.infoAsync(stable_id, cb)
    local url = HOST .. "/reader/book/info.json?source_uuid=" .. Text.urlEncode(stable_id)
    return getJson(url, function(wire, err)
        if not wire then cb(nil, err); return end
        if tonumber(wire.code) ~= 0 then cb(nil, type(wire.error) == "string" and wire.error or _("请求失败")); return end
        cb(wire)
    end)
end

---@param stable_id string
---@param content_uuid string
---@param cb fun(html: string|nil, err: string|nil)
---@return HttpJob
function Client.contentAsync(stable_id, content_uuid, cb)
    local url = HOST .. "/reader/book/content.json?source_uuid=" .. Text.urlEncode(stable_id)
        .. "&content_uuid=" .. Text.urlEncode(content_uuid)
    return getJson(url, function(wire, err)
        if not wire then cb(nil, err); return end
        if tonumber(wire.code) == -1 then cb(nil, _("本章未购买")); return end
        if tonumber(wire.code) ~= 0 then cb(nil, _("请求失败")); return end
        local html = Mapper.content(wire)
        if not html then cb(nil, _("正文为空")); return end
        cb(html)
    end)
end

--- 书籍评论。第一页，和网页一样每页 4 条。
---@param stable_id string
---@param cb fun(items: table[]|nil, err: string|nil, pages: integer|nil)
---@return HttpJob
function Client.commentsAsync(stable_id, cb)
    local url = HOST .. "/sns/comment/get.json?type=2&page=1&pageSize=4&id=" .. Text.urlEncode(stable_id)
    return getJson(url, function(wire, err)
        if not wire then cb(nil, err); return end
        if tonumber(wire.code) == -999 then cb(nil, _("未登录网易云阅读")); return end
        local items, pages = Mapper.comments(wire)
        if not items then cb(nil, _("网易云阅读书评加载失败")); return end
        cb(items, nil, pages)
    end)
end

---@return { cancel: fun(), cancelled: boolean, job: HttpJob|nil }
local function handle()
    local state = { cancelled = false }
    function state.cancel()
        state.cancelled = true
        if state.job and state.job.cancel then state.job.cancel() end
    end
    return state
end

---@param code any
---@return string
local function passwordError(code)
    local n = tonumber(code)
    if n == -1401 or n == -1403 then return _("网易云阅读手机号未注册") end
    if n == -1402 or n == -1404 then return _("网易云阅读密码错误") end
    if n == -1405 then return _("网易云阅读验证码错误") end
    if n == -1 then return _("请使用验证码方式登录网易云阅读") end
    return _("登录失败")
end

---@param code any
---@return string
local function smsError(code)
    if tonumber(code) == -749 then return _("网易云阅读验证错误，请重试") end
    return _("网易云阅读验证码错误")
end

---@param msg string
---@return string
local function dropSession(msg)
    local settings = require("utils.settings")
    local cfg = settings.getSource(SOURCE_ID)
    cfg.logged_in, cfg.cookie, cfg.csrf = nil, nil, nil
    settings.saveSource(SOURCE_ID)
    Client.reset()
    return require("source.auth").expire(SOURCE_ID, msg)
end

---@param state { cancelled: boolean, job: HttpJob|nil }
---@param cb fun(ok: boolean|nil, err: string|nil)
local function prepare(state, cb)
    Client.load()
    state.job = Request.get(HOST .. "/login.do", opts(), function(raw, err, res)
        if state.cancelled then return end
        absorb(res)
        local token = type(raw) == "string" and raw:match('id="csrf_token"[^>]*value="([^"]+)"') or nil
        if not token or token == "" then cb(nil, err and tostring(err) or _("登录失败")); return end
        csrf_token = token
        Client.persist()
        cb(true)
    end)
end

---@param state { cancelled: boolean, job: HttpJob|nil }
---@param path string
---@param fields table
---@param cb fun(wire: table|nil, err: string|nil)
local function postForm(state, path, fields, cb)
    Client.load()
    state.job = Request.post(HOST .. path, Text.formEncode(fields), opts(), function(raw, err, res)
        if state.cancelled then return end
        if absorb(res) and require("utils.settings").getSource(SOURCE_ID).logged_in == true then
            Client.persist()
        end
        if not raw or raw == "" then cb(nil, err and tostring(err) or _("请求失败")); return end
        local ok, wire = pcall(JSON.decode, raw)
        if not ok or type(wire) ~= "table" then cb(nil, _("请求失败")); return end
        cb(wire)
    end)
end

---@param state { cancelled: boolean, job: HttpJob|nil }
---@param cb fun(ok: boolean|nil, err: string|nil)
local function confirm(state, cb)
    state.job = Request.get(HOST .. "/login/context.json", opts(), function(raw, err, res)
        if state.cancelled then return end
        absorb(res)
        local ok, wire = pcall(JSON.decode, raw or "")
        local data = ok and type(wire) == "table" and wire.data or nil
        if not ok or type(wire) ~= "table" or tonumber(wire.code) ~= 0
            or type(data) ~= "table" or data.user == nil then
            cb(nil, err and tostring(err) or _("登录失败"))
            return
        end
        if type(data.csrf_token) == "string" and data.csrf_token ~= "" then csrf_token = data.csrf_token end
        local settings = require("utils.settings")
        local cfg = settings.getSource(SOURCE_ID)
        cfg.logged_in = true
        cfg.cookie = Client.cookie()
        cfg.csrf = csrf_token
        settings.saveSource(SOURCE_ID)
        require("source.auth").ok(SOURCE_ID)
        cb(true)
    end)
end

--- 网页登录把 targetUrl 传成 false。这里跟它一样。
local LOGIN_TARGET = "false"

---@param phone string
---@param password string
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }
function Client.passwordLoginAsync(phone, password, cb)
    local state = handle()
    prepare(state, function(ok, err)
        if state.cancelled then return end
        if not ok then cb(nil, err); return end
        postForm(state, "/login/phone_number/submit.json", {
            phone = phone, password = password, targetUrl = LOGIN_TARGET, csrf_token = csrf_token,
        }, function(wire, post_err)
            if state.cancelled then return end
            if not wire then cb(nil, post_err); return end
            if wire.successful ~= true then cb(nil, passwordError(wire.code)); return end
            confirm(state, cb)
        end)
    end)
    return state
end

---@param phone string
---@param image_code string
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }
function Client.sendCodeAsync(phone, image_code, cb)
    local state = handle()
    Client.load()
    local url = HOST .. "/login/fastLogin/sendPhoneNoVerifyCode.do?" .. Text.formEncode({
        imageCode = image_code, phoneNo = phone,
    })
    state.job = Request.get(url, opts(), function(raw, err, res)
        if state.cancelled then return end
        absorb(res)
        Client.persist()
        local ok, wire = pcall(JSON.decode, raw or "")
        if not ok or type(wire) ~= "table" then cb(nil, err and tostring(err) or _("请求失败")); return end
        if wire.successful ~= true then
            if tonumber(wire.code) == -1405 then cb(nil, _("图形验证码错误")); return end
            cb(nil, _("登录失败"))
            return
        end
        cb(true)
    end)
    return state
end

---@param phone string
---@param code string
---@param password string|nil
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }
function Client.smsLoginAsync(phone, code, password, cb)
    local state = handle()
    local function finish(wire, post_err)
        if state.cancelled then return end
        if not wire then cb(nil, post_err); return end
        if wire.successful ~= true then cb(nil, smsError(wire.code)); return end
        local data = type(wire.data) == "table" and wire.data or nil
        if data and data.isFirstLogin == true then
            if type(password) ~= "string" or #password < 6 or #password > 16 then
                cb(nil, _("网易云阅读首次登录要先设置密码"))
                return
            end
            postForm(state, "/register/phoneNoFromFastLogin.json", {
                phoneNo = phone, verifyCode = code, password = password,
                targetUrl = LOGIN_TARGET, csrf_token = csrf_token,
            }, function(registered, register_err)
                if state.cancelled then return end
                if not registered then cb(nil, register_err); return end
                if registered.successful ~= true then
                    if tonumber(registered.code) == -749 then cb(nil, _("网易云阅读验证错误，请重试")); return end
                    cb(nil, _("设置失败，请重试"))
                    return
                end
                confirm(state, cb)
            end)
            return
        end
        confirm(state, cb)
    end
    prepare(state, function(ok, err)
        if state.cancelled then return end
        if not ok then cb(nil, err); return end
        postForm(state, "/login/fastLogin/checkPhoneNoVerifyCode.do", {
            phoneNo = phone, verifyCode = code, csrf_token = csrf_token, targetUrl = LOGIN_TARGET,
        }, finish)
    end)
    return state
end

--- 图形验证码是会话 cookie 上的图，给远程页展示，用户只回填图上的字。
---@param cb fun(image: string|nil, mime_or_err: string|nil)
---@return { cancel: fun() }
function Client.captchaAsync(cb)
    local state = handle()
    prepare(state, function(ok, err)
        if state.cancelled then return end
        if not ok then cb(nil, err); return end
        state.job = Request.get(HOST .. "/login/fastLogin/sendImageVerifyCode.do", opts(), function(raw, image_err, res)
            if state.cancelled then return end
            absorb(res)
            Client.persist()
            if type(raw) ~= "string" or raw == "" then
                cb(nil, image_err and tostring(image_err) or _("图形验证码加载失败"))
                return
            end
            local _ext, mime = require("utils.image").ext(raw)
            if not mime then cb(nil, _("图形验证码加载失败")); return end
            cb(Text.base64Encode(raw), mime)
        end)
    end)
    return state
end

---@param stable_id string
---@param toc BookChapter[]
---@param idx number
---@param fraction number|nil
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }
function Client.putProgressAsync(stable_id, toc, idx, fraction, cb)
    if not Client.loggedIn() then
        cb(nil, _("未登录网易云阅读"))
        return { cancel = function() end }
    end
    local fields = Mapper.readlog(stable_id, toc, idx, fraction, csrf_token, os.time() * 1000)
    if not fields then
        cb(nil, _("缺少网易云阅读章节位置"))
        return { cancel = function() end }
    end
    local state = handle()
    postForm(state, "/reader/book/readlog.json", fields, function(wire, err)
        if state.cancelled then return end
        if not wire then cb(nil, err or _("网易云阅读进度保存失败")); return end
        if tonumber(wire.code) == -999 then
            cb(nil, dropSession(_("网易云阅读登录已失效")))
            return
        end
        if tonumber(wire.code) ~= 0 then cb(nil, _("网易云阅读进度保存失败")); return end
        require("source.auth").ok(SOURCE_ID)
        cb(true)
    end)
    return state
end

return Client
