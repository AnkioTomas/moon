--[[--
塔读网页接口。

登录是微信开放平台扫码：qrconnect 拿 uuid，长轮询拿到 code 后交给
/webchat/invoke/ 换 Cookie。书架、搜索、目录是 HTML，正文是 JSON。

@module source.tadu.client
--]]

require("l10n").apply()
local JSON = require("json")
local Mapper = require("source.tadu.mapper")
local Request = require("http.request")
local Text = require("utils.text")
local _ = require("gettext")

local Client = {}

local SOURCE_ID = "tadu"
local ORIGIN = "https://www.tadu.com"
local LOGIN_EXPIRED = "塔读登录已失效，请点「重新登录」，用微信扫码。"
local SHELF_PAGES = 30

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
    if Client.cookie() == nil then Client.load() end
    return require("utils.settings").getSource(SOURCE_ID).logged_in == true and Client.cookie() ~= nil
end

---@param user { name: string }|nil
function Client.persist(user)
    local settings = require("utils.settings")
    local cfg = settings.getSource(SOURCE_ID)
    cfg.cookie = Client.cookie()
    cfg.logged_in = true
    if user and type(user.name) == "string" and user.name ~= "" then cfg.name = user.name end
    settings.saveSource(SOURCE_ID)
end

---@param res table|nil
local function absorb(res)
    if not res then return end
    for _idx, line in ipairs(Request.headerAll(res, "Set-Cookie")) do remember(line) end
end

---@param accept string
---@return table
local function opts(accept)
    local headers = {
        Accept = accept,
        Referer = ORIGIN .. "/",
    }
    local cookie = Client.cookie()
    if cookie then headers.Cookie = cookie end
    return { accept = accept, headers = headers, timeout = require("http.timeout").net(1) }
end

---@param cb fun(body: string|nil, err: string|nil)
local function doneHtml(cb)
    return function(raw, err, res)
        absorb(res)
        if not raw or raw == "" then cb(nil, err and tostring(err) or _("请求失败")); return end
        cb(raw)
    end
end

---@param url string
---@param cb fun(body: string|nil, err: string|nil)
---@return HttpJob
local function getHtml(url, cb)
    return Request.get(url, opts("text/html"), doneHtml(cb))
end

--- 微信扫码页。uuid 在页面的 /connect/qrcode/<uuid> 里。
---@param cb fun(uuid: string|nil, err: string|nil)
---@return HttpJob
function Client.qrCreateAsync(cb)
    local url = "https://open.weixin.qq.com/connect/qrconnect?" .. Text.formEncode({
        appid = "wxbb4e499689feeef9",
        redirect_uri = "https://www.tadu.com/webchat/invoke/",
        response_type = "code",
        scope = "snsapi_login",
        state = "STATE",
    })
    return Request.get(url, {
        accept = "text/html",
        timeout = require("http.timeout").net(1),
    }, function(raw, err)
        local uuid = Mapper.qrUuid(raw)
        if not uuid then cb(nil, err and tostring(err) or _("获取二维码失败")); return end
        cb(uuid)
    end)
end

--- 长轮询。微信会把连接挂到约 30 秒，超时给到默认网络超时的 1.5 倍。
---@param uuid string
---@param last integer|nil
---@param cb fun(kind: "ok"|"wait"|"fail"|"expired", wx_code: string|nil, errcode: integer|nil)
---@return HttpJob
function Client.qrPollAsync(uuid, last, cb)
    local query = { f = "json", uuid = uuid }
    if last then query["last"] = tostring(last) end
    return Request.get("https://long.open.weixin.qq.com/connect/l/qrconnect?" .. Text.formEncode(query), {
        accept = "application/json",
        timeout = require("http.timeout").net(1.5),
    }, function(raw, _err)
        local kind, wx_code, errcode = Mapper.wxStatus(raw)
        cb(kind, wx_code, errcode)
    end)
end

--- code 换塔读会话，再用 /user/info 确认。
---@param wx_code string
---@param cb fun(user: { name: string }|nil, err: string|nil)
---@return { cancel: fun() }
function Client.exchangeAsync(wx_code, cb)
    local handle = {}
    Client.load()
    local url = ORIGIN .. "/webchat/invoke/?" .. Text.formEncode({ code = wx_code, state = "STATE" })
    handle.job = Request.get(url, opts("text/html"), function(_raw, err, res)
        absorb(res)
        if err and not Client.cookie() then cb(nil, tostring(err)); return end
        handle.job = Request.post(ORIGIN .. "/user/info", "", opts("application/json"), function(raw, reason, info_res)
            absorb(info_res)
            local ok, wire = pcall(JSON.decode, raw or "")
            local user = ok and Mapper.user(wire) or nil
            if not user then cb(nil, reason and tostring(reason) or _("未登录塔读")); return end
            Client.persist(user)
            cb(user)
        end)
    end)
    return { cancel = function()
        if handle.job and handle.job.cancel then handle.job.cancel() end
    end }
end

---@param cb fun(html: string|nil, err: string|nil)
---@return { cancel: fun() }
function Client.shelfAsync(cb)
    Client.load()
    local handle = {}
    local chunks = {}
    local function page(n)
        handle.job = getHtml(ORIGIN .. "/tadu/space/reader?pgNum=" .. n, function(html, err)
            if not html then cb(nil, err); return end
            if n == 1 then
                local books, reason = Mapper.shelfPage(html)
                if not books then
                cb(nil, reason == "未登录塔读" and _("未登录塔读") or _("塔读书架页面无法识别"))
                return
            end
            end
            chunks[#chunks + 1] = html
            if n < SHELF_PAGES and Mapper.shelfHasNext(html, n) then page(n + 1); return end
            cb(table.concat(chunks, "\n"))
        end)
    end
    page(1)
    return { cancel = function()
        if handle.job and handle.job.cancel then handle.job.cancel() end
    end }
end

---@param stable_id string
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return HttpJob
function Client.addAsync(stable_id, cb)
    Client.load()
    return Request.get(ORIGIN .. "/api/v1/favorite/" .. Text.urlEncode(stable_id), opts("application/json"), function(raw, err, res)
        absorb(res)
        local ok, wire = pcall(JSON.decode, raw or "")
        local status = ok and type(wire) == "table" and tostring(wire.status) or ""
        if status == "901" and Client.loggedIn() then
            cb(nil, require("source.auth").expire(SOURCE_ID, _(LOGIN_EXPIRED)))
            return
        end
        if status == "200" or status == "902" then cb(true); return end
        local msg = ok and type(wire) == "table" and type(wire.msg) == "string" and wire.msg or nil
        cb(nil, msg or (err and tostring(err)) or _("请求失败"))
    end)
end

---@param stable_id string
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return HttpJob
function Client.removeAsync(stable_id, cb)
    Client.load()
    return Request.post(ORIGIN .. "/tadu/api/v1/delFavorites", "bookId=" .. Text.urlEncode(stable_id), opts("application/json"), function(raw, err, res)
        absorb(res)
        local ok, wire = pcall(JSON.decode, raw or "")
        local status = ok and type(wire) == "table" and tostring(wire.status) or ""
        if status == "200" then cb(true); return end
        local msg = ok and type(wire) == "table" and type(wire.msg) == "string" and wire.msg or nil
        cb(nil, msg or (err and tostring(err)) or _("移出塔读书架失败"))
    end)
end

---@param keyword string
---@param cb fun(html: string|nil, err: string|nil)
---@return HttpJob
function Client.searchAsync(keyword, cb)
    return Request.post(ORIGIN .. "/search", "query=" .. Text.urlEncode(keyword), opts("text/html"), doneHtml(cb))
end

---@param node string
---@param cb fun(html: string|nil, err: string|nil)
---@return HttpJob
function Client.channelAsync(node, cb)
    return getHtml(ORIGIN .. "/store/" .. node, cb)
end

---@param stable_id string
---@param cb fun(html: string|nil, err: string|nil)
---@return HttpJob
function Client.detailAsync(stable_id, cb)
    return getHtml(ORIGIN .. "/book/" .. Text.urlEncode(stable_id), cb)
end

---@param stable_id string
---@param cb fun(html: string|nil, err: string|nil)
---@return HttpJob
function Client.chaptersAsync(stable_id, cb)
    return getHtml(ORIGIN .. "/book/read/catalogue/" .. Text.urlEncode(stable_id), cb)
end

---@param stable_id string
---@param part string
---@param cb fun(html: string|nil, err: string|nil)
---@return HttpJob
function Client.contentAsync(stable_id, part, cb)
    local url = ORIGIN .. "/getPartContentByCodeTable/" .. Text.urlEncode(stable_id) .. "/" .. Text.urlEncode(part)
    return Request.get(url, opts("application/json"), function(raw, err, res)
        absorb(res)
        if not raw then cb(nil, err and tostring(err) or _("请求失败")); return end
        local ok, wire = pcall(JSON.decode, raw)
        if not ok then cb(nil, _("响应无效")); return end
        local html, reason = Mapper.content(wire)
        if html then cb(html); return end
        if reason == "响应无效" or not reason then cb(nil, _("响应无效")); return end
        cb(nil, reason)
    end)
end

return Client
