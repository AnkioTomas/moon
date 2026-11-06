--[[--
得到网页接口。

登录是得到 App 扫码：先拿匿名 Cookie 和 oauth access token，再轮询 check_login。
登录成功后的会话就是 Set-Cookie。书架是已购电子书，正文走阅读 token + SVG。

@module source.dedao.client
--]]

require("l10n").apply()
local JSON = require("json")
local Mapper = require("source.dedao.mapper")
local Request = require("http.request")
local Text = require("utils.text")
local _ = require("gettext")

local Client = {}

local SOURCE_ID = "dedao"
local ORIGIN = "https://www.dedao.cn"
local LOGIN_EXPIRED = "得到登录已失效，请点「重新登录」，用得到 App 扫码。"

-- 阅读器请求里 config 是驼峰。响应字段仍是 chapter_id / is_end / is_last。
local PAGE = {
    density = 1,
    direction = 1,
    fontName = "yahei",
    fontScale = 1,
    fontSize = 20,
    height = 1600,
    lineHeight = "2em",
    marginBottom = 100,
    marginLeft = 90,
    marginRight = 90,
    marginTop = 0,
    paragraphSpace = "1em",
    platform = 0,
    width = 900,
}

local jar = {}

local function remember(header)
    if type(header) ~= "string" or header == "" then return end
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
    jar = {}
end

function Client.load()
    Client.reset()
    remember(require("utils.settings").getSource(SOURCE_ID).cookie)
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

---@return boolean
function Client.loggedIn()
    local cfg = require("utils.settings").getSource(SOURCE_ID)
    return cfg.logged_in == true and cfg.cookie ~= nil and cfg.cookie ~= ""
end

function Client.persist()
    local settings = require("utils.settings")
    settings.getSource(SOURCE_ID).cookie = Client.cookie()
    settings.saveSource(SOURCE_ID)
end

---@param res table|nil
local function absorb(res)
    if not res then return end
    for _idx, line in ipairs(Request.headerAll(res, "Set-Cookie")) do remember(line) end
end

---@return string|nil
local function csrf()
    return jar.csrfToken
end

---@param extra table|nil
---@return table
local function headers(extra)
    local out = {
        ["Xi-DT"] = "web",
        Accept = "application/json",
    }
    local token = csrf()
    if token then out["Xi-Csrf-Token"] = token end
    local cookie = Client.cookie()
    if cookie then out.Cookie = cookie end
    for key, value in pairs(extra or {}) do out[key] = value end
    return out
end

---@param wire table
---@param authed boolean
---@return table|nil
---@return string|nil
local function payload(wire, authed)
    local head = type(wire.h) == "table" and wire.h or nil
    local code = tonumber(head and head.c or wire.errCode)
    if not code then return nil, _("响应无效") end
    if code ~= 0 then
        if authed and code == 401 then
            return nil, require("source.auth").expire(SOURCE_ID, _(LOGIN_EXPIRED))
        end
        local message = head and head.e
        return nil, type(message) == "string" and message ~= "" and message or _("请求失败")
    end
    if authed and code == 0 then require("source.auth").ok(SOURCE_ID) end
    if wire.c ~= nil then return wire.c end
    return wire
end

---@param method string
---@param path string
---@param body string|nil
---@param extra table|nil
---@param content_type string|nil
---@param cb fun(body: any, err: string|nil, res: table|nil)
---@return HttpJob
local function call(method, path, body, extra, content_type, cb)
    local url = path:find("^https?://") and path or ORIGIN .. path
    local opts = {
        accept = "application/json",
        headers = headers(extra),
        timeout = require("http.timeout").net(0.5),
    }
    if content_type then opts.content_type = content_type end
    local function done(raw, err, res)
        absorb(res)
        if not raw then cb(nil, err and tostring(err) or _("请求失败"), res); return end
        local ok, wire = pcall(JSON.decode, raw)
        if not ok or type(wire) ~= "table" then cb(nil, _("响应无效"), res); return end
        local data, reason = payload(wire, Client.loggedIn())
        cb(data, reason, res)
    end
    if method == "POST" then return Request.post(url, body, opts, done) end
    return Request.get(url, opts, done)
end

---@param cb fun(ok: boolean|nil, err: string|nil)
---@return HttpJob
function Client.bootstrapAsync(cb)
    Client.load()
    if csrf() then return require("source.base").defer(cb, true) end
    return Request.get(ORIGIN .. "/", {
        accept = "text/html",
        timeout = require("http.timeout").net(0.5),
    }, function(_raw, err, res)
        absorb(res)
        if not csrf() then cb(nil, err and tostring(err) or _("请求失败")); return end
        Client.persist()
        cb(true)
    end)
end

---@param cb fun(token: string|nil, err: string|nil)
---@return { cancel: fun() }
function Client.accessTokenAsync(cb)
    local handle = {}
    handle.job = Client.bootstrapAsync(function(ok, err)
        if not ok then cb(nil, err); return end
        handle.job = Request.post(ORIGIN .. "/loginapi/getAccessToken", "", {
            headers = headers(),
            accept = "application/json",
            content_type = "application/json",
            timeout = require("http.timeout").net(0.5),
        }, function(raw, reason, res)
            absorb(res)
            if not raw then cb(nil, reason and tostring(reason) or _("获取二维码失败")); return end
            local decoded, wire = pcall(JSON.decode, raw)
            local token = decoded and wire or Text.trim(raw)
            if type(token) == "table" then
                local data, err = payload(token, false)
                reason = err
                token = type(data) == "table" and data.token or data
            end
            if type(token) ~= "string" or token == "" then cb(nil, reason or _("获取二维码失败")); return end
            cb(token)
        end)
    end)
    return { cancel = function()
        if handle.job and handle.job.cancel then handle.job.cancel() end
    end }
end

---@param oauth string
---@param cb fun(code: string|nil, err: string|nil)
---@return HttpJob
function Client.qrCreateAsync(oauth, cb)
    return call("GET", "/oauth/api/embedded/qrcode", nil, { ["X-Oauth-Access-Token"] = oauth }, nil, function(body, err)
        local data = type(body) == "table" and body.data or nil
        local code = type(data) == "table" and data.qrCodeString or nil
        if type(code) ~= "string" or code == "" then cb(nil, err or _("获取二维码失败")); return end
        cb(code)
    end)
end

---@param oauth string
---@param code string
---@param cb fun(wire: table|nil, err: string|nil)
---@return HttpJob
function Client.qrPollAsync(oauth, code, cb)
    return call("POST", "/oauth/api/embedded/qrcode/check_login", JSON.encode({
        qrCode = code, keepLogin = true,
    }), { ["X-Oauth-Access-Token"] = oauth }, "application/json", function(body, err)
        if type(body) ~= "table" or body.data == nil then cb(nil, err or _("请求失败")); return end
        if Mapper.login(body) == "ok" then Client.persist() end
        cb(body, err)
    end)
end

local function authed(cb)
    Client.load()
    if Client.loggedIn() then return nil end
    return require("source.base").defer(cb, nil, _("未登录得到"))
end

---@param cb fun(body: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client.shelfAsync(cb)
    local denied = authed(cb)
    if denied then return denied end
    local handle, rows = {}, {}
    local function nextPage(page)
        handle.job = call("POST", "/api/hades/v2/product/list", JSON.encode({
            category = "ebook",
            display_group = true,
            filter = "all",
            filter_complete = 0,
            group_id = 0,
            order = "study",
            page = page,
            page_size = 18,
            sort_type = "desc",
        }), nil, "application/json", function(body, err)
            if type(body) ~= "table" or type(body.list) ~= "table" then cb(nil, err); return end
            for _idx, row in ipairs(body.list) do rows[#rows + 1] = row end
            if (body.is_more == true or body.is_more == 1) and page < 40 then
                nextPage(page + 1)
                return
            end
            cb({ list = rows, is_more = false })
        end)
    end
    nextPage(1)
    return { cancel = function()
        if handle.job and handle.job.cancel then handle.job.cancel() end
    end }
end

---@param stable_id string
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return HttpJob|{ cancel: fun() }
function Client.addAsync(stable_id, cb)
    local denied = authed(cb)
    if denied then return denied end
    return call("POST", "/api/pc/ebook2/v1/bookshelf/add", JSON.encode({
        book_enids = { stable_id }, ptype = 2,
    }), nil, "application/json", function(body, err)
        cb(body and true or nil, err)
    end)
end

---@param stable_id string
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return HttpJob|{ cancel: fun() }
function Client.removeAsync(stable_id, cb)
    local denied = authed(cb)
    if denied then return denied end
    return call("POST", "/api/pc/ebook2/v1/bookshelf/remove", JSON.encode({
        book_enids = { stable_id },
    }), nil, "application/json", function(body, err)
        cb(body and true or nil, err)
    end)
end

---@param keyword string
---@param cb fun(body: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client.searchAsync(keyword, cb)
    local handle = {}
    handle.job = Client.bootstrapAsync(function(ok, err)
        if not ok then cb(nil, err); return end
        handle.job = call("POST", "/api/search/pc/tophits", JSON.encode({
            content = keyword, page = 1, page_size = 20, search_type = 0, tab_type = 2,
        }), nil, "application/json", cb)
    end)
    return { cancel = function()
        if handle.job and handle.job.cancel then handle.job.cancel() end
    end }
end

---@param stable_id string
---@param cb fun(body: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client.detailAsync(stable_id, cb)
    local handle = {}
    handle.job = Client.bootstrapAsync(function(ok, err)
        if not ok then cb(nil, err); return end
        handle.job = call("GET", "/pc/ebook2/v1/pc/detail?" .. Text.formEncode({ id = stable_id, ptype = 2 }), nil, nil, nil, cb)
    end)
    return { cancel = function()
        if handle.job and handle.job.cancel then handle.job.cancel() end
    end }
end

---@param stable_id string
---@param cb fun(token: string|nil, err: string|nil)
---@return HttpJob|{ cancel: fun() }
function Client.readTokenAsync(stable_id, cb)
    local denied = authed(cb)
    if denied then return denied end
    return call("POST", "/api/pc/ebook2/v1/pc/read/token", JSON.encode({ id = stable_id }), nil, "application/json", function(body, err)
        local token = type(body) == "table" and body.token or nil
        if type(token) ~= "string" or token == "" then cb(nil, err or _("请求失败")); return end
        cb(token)
    end)
end

---@param stable_id string
---@param cb fun(info: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client.bookInfoAsync(stable_id, cb)
    local handle = {}
    handle.job = Client.readTokenAsync(stable_id, function(token, err)
        if not token then cb(nil, err); return end
        handle.job = call("GET", "/ebk_web/v1/get_book_info?" .. Text.formEncode({ token = token }), nil, nil, nil, cb)
    end)
    return { cancel = function()
        if handle.job and handle.job.cancel then handle.job.cancel() end
    end }
end

---@param token string
---@param chapter_id string
---@param index integer
---@param cb fun(body: table|nil, err: string|nil)
---@return HttpJob
local function pages(token, chapter_id, index, cb)
    return call("POST", "/ebk_web_go/v2/get_pages", JSON.encode({
        chapter_id = chapter_id,
        config = PAGE,
        count = 20,
        index = index,
        offset = 0,
        orientation = 0,
        token = token,
    }), nil, "application/json", cb)
end

---@param stable_id string
---@param chapter_id string
---@param cb fun(text: string|nil, err: string|nil, kind: "unpaid"|nil)
---@return { cancel: fun() }
function Client.contentAsync(stable_id, chapter_id, cb)
    local handle = {}
    handle.job = Client.readTokenAsync(stable_id, function(token, err)
        if not token then cb(nil, err); return end
        local parts = {}
        local function nextIndex(index, guard)
            if guard > 40 then cb(nil, _("响应无效")); return end
            handle.job = pages(token, chapter_id, index, function(body, reason)
                if type(body) ~= "table" then
                    if reason == "user no legal!" then cb(nil, _("本章未购买"), "unpaid"); return end
                    cb(nil, reason or _("响应无效"))
                    return
                end
                local list = body.pages
                if type(list) ~= "table" then cb(nil, _("响应无效")); return end
                for _idx, page in ipairs(list) do
                    local text = type(page) == "table" and Mapper.pageText(page.svg) or nil
                    if text == nil then cb(nil, _("响应无效")); return end
                    if text ~= "" then parts[#parts + 1] = text end
                end
                local last = list[#list]
                if body.is_end == true or (type(last) == "table" and last.is_last == true) then
                    if #parts == 0 then cb(nil, _("响应无效")); return end
                    cb(table.concat(parts, "\n\n"))
                    return
                end
                if #list == 0 then cb(nil, _("响应无效")); return end
                nextIndex(index + #list, guard + 1)
            end)
        end
        nextIndex(0, 1)
    end)
    return { cancel = function()
        if handle.job and handle.job.cancel then handle.job.cancel() end
    end }
end

---@param stable_id string
---@param cb fun(item: table|nil, err: string|nil)
---@return HttpJob|{ cancel: fun() }
function Client.progressAsync(stable_id, cb)
    local denied = authed(cb)
    if denied then return denied end
    return call("POST", "/api/pc/ebook2/v1/pc/getread", JSON.encode({ id = stable_id }), nil, "application/json", function(body, err)
        if type(body) ~= "table" then cb(nil, err); return end
        cb(body.data or body)
    end)
end

---@param stable_id string
---@param chapter_id string
---@param summary string
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return HttpJob|{ cancel: fun() }
function Client.putProgressAsync(stable_id, chapter_id, summary, cb)
    local denied = authed(cb)
    if denied then return denied end
    return call("POST", "/api/pc/ebook2/v1/pc/addread", JSON.encode({
        findex = chapter_id, windex = 0, id = stable_id, summary = summary,
    }), nil, "application/json", function(body, err)
        cb(body and true or nil, err)
    end)
end

return Client
