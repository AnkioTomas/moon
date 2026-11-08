--[[--
塔读电脑 Web 接口。公开查询不带 Cookie，书架和付费正文使用当前登录。
扫码兑换的 Cookie 归请求实例所有，校验通过才替换持久会话。

@module source.tadu.client
--]]

local JSON = require("json")
local Mapper = require("source.tadu.mapper")
local Request = require("http.request")
local Text = require("utils.text")
local _ = require("l10n").get("source.tadu")

local Client = {}
local SOURCE_ID = "tadu"
local ORIGIN = "https://www.tadu.com"

function Client.cookie()
    return require("utils.settings").getSource(SOURCE_ID).cookie
end

function Client.loggedIn()
    local cfg = require("utils.settings").getSource(SOURCE_ID)
    return cfg.logged_in == true and type(cfg.cookie) == "string" and cfg.cookie ~= ""
        and not require("source.auth").expired(SOURCE_ID)
end

local function opts(accept, cookie)
    return {
        accept = accept, cache_ttl = 0,
        headers = { Referer = ORIGIN .. "/", Cookie = cookie },
        timeout = require("http.timeout").net(1),
    }
end

local function doneHtml(cb)
    return function(raw, err)
        if err or not raw or raw == "" then
            cb(nil, err and tostring(err) or _("请求失败"))
            return
        end
        cb(raw)
    end
end

local function decoded(raw, err)
    if err or not raw then return nil, err and tostring(err) or _("请求失败") end
    local ok, wire = pcall(JSON.decode, raw)
    if not ok or type(wire) ~= "table" then return nil, _("响应无效") end
    return wire
end

local function expired(cookie)
    local reason = _("塔读登录已失效，请在官网重新登录")
    if cookie == Client.cookie() then require("source.auth").expire(SOURCE_ID, reason) end
    return reason
end

--- 站点没有稳定账号 ID：凭据变化就直接清旧源记录。
function Client.commitLogin(cookie, user)
    local Settings = require("utils.settings")
    local cfg = Settings.getSource(SOURCE_ID)
    local old = require("source.cookie_login").parse(Client.cookie() or "")
    if old ~= "" and old ~= require("source.cookie_login").parse(cookie) then
        local cleared = require("source.logout").clear(SOURCE_ID, function()
            cfg.cookie, cfg.logged_in, cfg.name = nil, nil, nil
            cfg.read_cookie, cfg.read_cookie_for = nil, nil
            Settings.saveSource(SOURCE_ID)
        end)
        if not cleared then return nil, _("清除本地记录失败") end
    end
    cfg.cookie, cfg.logged_in, cfg.name = cookie, true, user.name
    Settings.saveSource(SOURCE_ID)
    return true
end

function Client.loginCheckAsync(cookie, cb)
    local previous = Client.cookie()
    return Request.post(ORIGIN .. "/user/info", "", opts("application/json", cookie), function(raw, err)
        local wire, reason = decoded(raw, err)
        if not wire then cb(false, reason); return end
        local user = Mapper.user(wire)
        if not user then cb(false, _("未登录塔读")); return end
        if Client.cookie() ~= previous then cb(false, _("塔读登录已改变，请重试")); return end
        cb(true, nil, user)
    end)
end

function Client.qrCreateAsync(cb)
    local url = "https://open.weixin.qq.com/connect/qrconnect?" .. Text.formEncode({
        appid = "wxbb4e499689feeef9",
        redirect_uri = ORIGIN .. "/webchat/invoke/",
        response_type = "code", scope = "snsapi_login", state = "STATE",
    })
    return Request.get(url, { accept = "text/html", cache_ttl = 0, timeout = require("http.timeout").net(1) },
        function(raw, err)
            if err then cb(nil, tostring(err)); return end
            local uuid = Mapper.qrUuid(raw)
            cb(uuid, not uuid and _("获取二维码失败") or nil)
        end)
end

function Client.qrPollAsync(uuid, last, cb)
    local query = { f = "json", uuid = uuid, last = last and tostring(last) }
    return Request.get("https://long.open.weixin.qq.com/connect/l/qrconnect?" .. Text.formEncode(query), {
        accept = "application/json", cache_ttl = 0, timeout = require("http.timeout").net(1.5),
    }, function(raw, err)
        if err then cb("error", nil, nil, tostring(err)); return end
        local kind, code, status = Mapper.wxStatus(raw)
        if not status then cb("error", nil, nil, _("响应无效")); return end
        cb(kind, code, status)
    end)
end

function Client.exchangeAsync(wx_code, cb)
    local handle, cookies, previous = {}, {}, Client.cookie()
    local function cookie()
        local names, parts = {}, {}
        for name in pairs(cookies) do names[#names + 1] = name end
        table.sort(names)
        for _idx, name in ipairs(names) do parts[#parts + 1] = name .. "=" .. cookies[name] end
        return table.concat(parts, "; ")
    end
    local function request(method, url, done)
        local pending = true
        local function reply(raw, err, res)
            pending = false
            if handle.cancelled then return end
            handle.job = nil
            for _idx, line in ipairs(Request.headerAll(res, "Set-Cookie")) do
                local name, value = line:match("^%s*([^=;%s]+)=([^;]*)")
                if name then cookies[name] = value ~= "" and value ~= '""' and value or nil end
            end
            done(raw, err, res)
        end
        local options = opts(method == "POST" and "application/json" or "text/html", cookie())
        local job
        if method == "POST" then job = Request.post(url, "", options, reply)
        else job = Request.get(url, options, reply) end
        if pending then handle.job = job end
    end
    local function confirm()
        request("POST", ORIGIN .. "/user/info", function(raw, err)
            local wire, reason = decoded(raw, err)
            local user = wire and Mapper.user(wire)
            if not user or cookie() == "" then cb(nil, reason or _("未登录塔读")); return end
            if Client.cookie() ~= previous then cb(nil, _("塔读登录已改变，请重试")); return end
            local ok, failure = Client.commitLogin(cookie(), user)
            if not ok then cb(nil, failure); return end
            cb(user)
        end)
    end
    local function follow(url, remaining)
        request("GET", url, function(raw, err, res)
            local status = res and tonumber(res.code)
            if status and status >= 300 and status < 400 then
                local location = Request.header(res, "Location")
                if location and location:sub(1, 1) == "/" and location:sub(1, 2) ~= "//" then
                    location = ORIGIN .. location
                end
                if remaining == 0 or type(location) ~= "string"
                    or location:sub(1, #ORIGIN + 1) ~= ORIGIN .. "/" then
                    cb(nil, _("塔读登录回调无效"))
                    return
                end
                follow(location, remaining - 1)
                return
            end
            if err or not raw then cb(nil, err and tostring(err) or _("请求失败")); return end
            confirm()
        end)
    end
    follow(ORIGIN .. "/webchat/invoke/?" .. Text.formEncode({ code = wx_code, state = "STATE" }), 5)
    function handle.cancel()
        handle.cancelled = true
        if handle.job then handle.job.cancel() end
    end
    return handle
end

function Client.shelfAsync(cb)
    local handle, chunks, cookie = {}, {}, Client.cookie()
    local function page(n)
        local pending = true
        local job = Request.get(ORIGIN .. "/tadu/space/reader?pgNum=" .. n, opts("text/html", cookie),
            function(raw, err)
                pending = false
                if handle.cancelled then return end
                handle.job = nil
                if err or not raw then cb(nil, err and tostring(err) or _("请求失败")); return end
                if cookie ~= Client.cookie() then cb(nil, _("塔读登录已改变，请重试")); return end
                local books, reason = Mapper.shelfPage(raw)
                if not books then
                    cb(nil, reason == "未登录塔读" and expired(cookie) or _("塔读书架页面无法识别"))
                    return
                end
                chunks[#chunks + 1] = raw
                if Mapper.shelfHasNext(raw, n) then
                    if n == 1000 then cb(nil, _("塔读书架分页异常")); return end
                    page(n + 1)
                    return
                end
                cb(table.concat(chunks, "\n"))
            end)
        if pending then handle.job = job end
    end
    page(1)
    function handle.cancel()
        handle.cancelled = true
        if handle.job then handle.job.cancel() end
    end
    return handle
end

local function changeShelf(method, url, body, stable_id, cb)
    local cookie = Client.cookie()
    local handle, pending = {}, true
    local function done(raw, err)
        pending = false
        if handle.cancelled then return end
        handle.job = nil
        local wire, reason = decoded(raw, err)
        if not wire then cb(nil, reason); return end
        if cookie ~= Client.cookie() then cb(nil, _("塔读登录已改变，请重试")); return end
        local status = tonumber(wire.status)
        if status == 901 then cb(nil, expired(cookie)); return end
        if status == 200 or (method == "GET" and status == 902) then
            local checking = true
            local job = Client.shelfAsync(function(html, shelf_err)
                checking = false
                if handle.cancelled then return end
                handle.job = nil
                if cookie ~= Client.cookie() then cb(nil, _("塔读登录已改变，请重试")); return end
                if not html then cb(nil, shelf_err); return end
                local found = false
                for _idx, book in ipairs(Mapper.shelf(html)) do
                    if book.stable_id == stable_id then found = true; break end
                end
                if found ~= (method == "GET") then cb(nil, _("塔读书架修改未确认，请稍后重试")); return end
                cb(true)
            end)
            if checking then handle.job = job end
            return
        end
        cb(nil, type(wire.msg) == "string" and wire.msg ~= "" and wire.msg or _("响应无效"))
    end
    local job
    if method == "GET" then job = Request.get(url, opts("application/json", cookie), done)
    else job = Request.post(url, body, opts("application/json", cookie), done) end
    if pending then handle.job = job end
    function handle.cancel()
        handle.cancelled = true
        if handle.job then handle.job.cancel() end
    end
    return handle
end

function Client.addAsync(stable_id, cb)
    return changeShelf("GET", ORIGIN .. "/api/v1/favorite/" .. Text.urlEncode(stable_id), nil, stable_id, cb)
end

function Client.removeAsync(stable_id, cb)
    return changeShelf("POST", ORIGIN .. "/tadu/api/v1/delFavorites", "bookId=" .. Text.urlEncode(stable_id), stable_id, cb)
end

function Client.searchAsync(keyword, cb)
    return Request.post(ORIGIN .. "/search", "query=" .. Text.urlEncode(keyword), opts("text/html"), doneHtml(cb))
end

function Client.channelAsync(node, cb)
    if node ~= nil and not Mapper.storeNode(node) then
        return require("source.base").defer(cb, nil, _("响应无效"))
    end
    return Request.get(ORIGIN .. "/store" .. (node and "/" .. node or ""), opts("text/html"), doneHtml(cb))
end

function Client.detailAsync(stable_id, cb)
    return Request.get(ORIGIN .. "/book/" .. Text.urlEncode(stable_id), opts("text/html"), doneHtml(cb))
end

function Client.chaptersAsync(stable_id, cb)
    return Request.get(ORIGIN .. "/book/read/catalogue/" .. Text.urlEncode(stable_id), opts("text/html"), doneHtml(cb))
end

---@class TaduReading
---@field stable_id string
---@field chapter_uid string
---@field previous string|nil
---@field cookie string|nil
---@field active table|nil
---@field authorization TaduReadAuth|nil
---@field cancelled boolean|nil
local Reading = {}
Reading.__index = Reading

function Reading:stop()
    local active = self.active
    self.active = nil
    if active and active.job then active.job.cancel() end
end

function Reading:cancel()
    self.cancelled = true
    self:stop()
    if self.authorization then self.authorization:cancel() end
end

function Reading:request(path, accept, cb)
    if self.cancelled then return end
    local active = {}
    self.active = active
    active.job = Request.get(ORIGIN .. path, opts(accept, self.cookie), function(raw, err, res)
        if self.active ~= active or self.cancelled then return end
        self.active = nil
        if self.previous ~= Client.cookie() then cb(nil, _("塔读登录已改变，请重试")); return end
        if err or not raw then cb(nil, err and tostring(err) or _("请求失败")); return end
        local cookies, names, parts = {}, {}, {}
        for name, value in (self.cookie or ""):gmatch("([^=;%s]+)=([^;]*)") do cookies[name] = value end
        for _idx, line in ipairs(Request.headerAll(res, "Set-Cookie")) do
            local name, value = line:match("^%s*([^=;%s]+)=([^;]*)")
            if name then cookies[name] = value ~= "" and value ~= '""' and value or nil end
        end
        for name in pairs(cookies) do names[#names + 1] = name end
        table.sort(names)
        for _idx, name in ipairs(names) do parts[#parts + 1] = name .. "=" .. cookies[name] end
        self.cookie = table.concat(parts, "; ")
        cb(raw)
    end)
end

function Reading:qrCreateAsync(cb)
    self:request("/qrcode/invoke", "application/json", function(raw, err)
        local wire, reason = decoded(raw, err)
        local data = wire and wire.data
        if not wire or wire.status ~= 200 or type(data) ~= "table"
            or type(data.qid) ~= "string" or data.qid == ""
            or type(data.token) ~= "string" or data.token == ""
            or type(data.qrcode) ~= "string" then
            cb(nil, reason or _("获取二维码失败"))
            return
        end
        local encoded = data.qrcode:match("^data:image/png;base64,([A-Za-z0-9+/=]+)$")
        local image = encoded and Text.base64Decode(encoded)
        if not image or image == "" then cb(nil, _("获取二维码失败")); return end
        cb({ qid = data.qid, token = data.token, image = image })
    end)
end

function Reading:qrPollAsync(ticket, cb)
    self:request("/qrcode/check?" .. Text.formEncode({ qid = ticket.qid, token = ticket.token }),
        "application/json", function(raw, err)
            local wire, reason = decoded(raw, err)
            if not wire or type(wire.status) ~= "number" then cb(nil, reason or _("响应无效")); return end
            cb(wire.status)
        end)
end

function Reading:complete(html, err, cb)
    if self.previous ~= Client.cookie() then cb(nil, _("塔读登录已改变，请重试")); return end
    if html then
        local settings = require("utils.settings")
        local cfg = settings.getSource(SOURCE_ID)
        if self.cookie ~= (self.previous or "")
            and (cfg.read_cookie ~= self.cookie or cfg.read_cookie_for ~= (self.previous or "")) then
            cfg.read_cookie, cfg.read_cookie_for = self.cookie, self.previous or ""
            settings.saveSource(SOURCE_ID)
        end
    end
    cb(html, err)
end

function Reading:fontAsync(font, cb)
    if font.url:sub(1, #ORIGIN + 1) ~= ORIGIN .. "/" then
        cb(nil, _("塔读章节字体还原失败，请重试"))
        return
    end
    self:request(font.url:sub(#ORIGIN + 1), "application/octet-stream", function(bytes, err)
        if not bytes then cb(nil, err); return end
        local active = {}
        self.active = active
        local job = require("source.tadu.font").restoreAsync(font.html, bytes, function(html, reason)
            if self.cancelled or self.active ~= active then return end
            self.active = nil
            self:complete(html, reason, cb)
        end)
        active.job = { cancel = function() job:cancel() end }
    end)
end

function Reading:contentAsync(cb, interactive)
    self:request("/book/" .. Text.urlEncode(self.stable_id) .. "/" .. Text.urlEncode(self.chapter_uid) .. "/",
        "text/html", function(page, err)
            if not page then cb(nil, err); return end
            local reading = Mapper.reading(page, self.stable_id)
            if not reading then cb(nil, _("塔读阅读页无法识别")); return end
            if reading.gated then
                if interactive then
                    self.authorization = require("source.tadu.read_auth").new(self, cb)
                else
                    cb(nil, _("塔读此章节需要 App 扫码授权，请先打开章节扫码阅读"))
                end
                return
            end
            self:request(reading.resource, "application/json", function(raw, content_err)
                local wire, reason = decoded(raw, content_err)
                if not wire then cb(nil, reason); return end
                local html, parse_err, font = Mapper.content(wire, self.chapter_uid)
                if font then self:fontAsync(font, cb); return end
                self:complete(html, html == nil and parse_err and _(parse_err) or nil, cb)
            end)
        end)
end

function Client.contentAsync(stable_id, _part, cb, chapter_uid, interactive)
    local previous = Client.cookie()
    local cfg = require("utils.settings").getSource(SOURCE_ID)
    local reading = setmetatable({
        stable_id = stable_id, chapter_uid = chapter_uid, previous = previous,
        cookie = cfg.read_cookie_for == (previous or "") and cfg.read_cookie or previous,
    }, Reading)
    reading:contentAsync(cb, interactive)
    return { cancel = function() reading:cancel() end }
end

function Client.reviewsAsync(stable_id, cb)
    return Request.get(ORIGIN .. "/v4/book/comment/" .. Text.urlEncode(stable_id) .. "/1/1",
        opts("text/html"), function(raw, err)
            if err or not raw then cb(nil, err and tostring(err) or _("请求失败")); return end
            local items, pages = Mapper.reviews(raw)
            cb(items, not items and _("响应无效") or nil, pages)
        end)
end

return Client
