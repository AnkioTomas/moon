--[[--
快看漫画网页接口。

搜索和首页是 JSON。目录在话题页 HTML 里。页图要先拿挑战接口的 `kk_s_t`，
再按页面脚本的算法算出 `answer`。公共请求不携带账号 Cookie。

@module source.kuaikan.client
--]]

local JSON = require("json")
local Mapper = require("source.kuaikan.mapper")
local Page = require("source.kuaikan.page")
local Request = require("http.request")
local Text = require("utils.text")
local _ = require("l10n").get("source.kuaikan")

local Client = {}
Client.login_revision = 0

local HOST = "https://www.kuaikanmanhua.com"
Client.LOGIN_URL = HOST .. "/webs/loginh"
Client.ACCOUNT_URL = HOST .. "/v2/pweb/user_info/get"
local ALPHA = "BtMTUlesLXPIFjfcbGYWyqQxROzAHNDCwmiKpdhvkSrEungZoJaV"
local PREFIX = "20200820"

---@return table
local function opts(extra)
    local out = { timeout = require("http.timeout").net(1) }
    if extra then
        for key, value in pairs(extra) do out[key] = value end
    end
    return out
end

---@param res table|nil
---@return string|nil
local function cookieOf(res)
    local lines = {}
    if Request.headerAll then
        lines = Request.headerAll(res, "set-cookie") or {}
    else
        local line = Request.header(res, "set-cookie")
        if type(line) == "string" then lines = { line } end
    end
    for _idx, line in ipairs(lines) do
        local value = type(line) == "string" and line:match("kk_s_t=([^;]+)") or nil
        if value and value ~= "" then return value end
    end
    return nil
end

--- 页面 `getSign` 的结果。indexes 是 16 个 0..15 的下标，缺省用随机数。
---@param cookie string
---@param indexes integer[]|nil
---@return string
function Client.answer(cookie, indexes)
    local rand = {}
    for slot = 1, 16 do
        local index = indexes and indexes[slot] or math.random(0, 15)
        rand[#rand + 1] = tostring(index) .. ALPHA:sub(index + 1, index + 1)
    end
    local rand_s = table.concat(rand)
    local body = PREFIX .. rand_s .. cookie
    if #body % 2 ~= 0 then body = body .. "0" end
    local mid = #body / 2
    local slice = body:sub(mid - 16 + 1, mid + 16)
    return Text.base64Encode(table.concat({ PREFIX, rand_s, cookie, slice }, "_"))
end

--- 登录态在 settings.cookie。页图还要拼上挑战接口的 kk_s_t。
---@param headers table|nil
---@return table|nil
local function withCookie(headers, cookie)
    if cookie == nil then cookie = require("utils.settings").getSource("kuaikan").cookie end
    local saved = type(cookie) == "string" and cookie or ""
    if saved == "" then return headers end
    headers = headers or {}
    if type(headers.Cookie) == "string" and headers.Cookie ~= "" then
        local pairs = {}
        for pair in saved:gmatch("[^;]+") do
            if pair:match("^%s*([^=%s]+)%s*=") ~= "kk_s_t" then
                pairs[#pairs + 1] = Text.trim(pair)
            end
        end
        saved = table.concat(pairs, "; ")
        if saved ~= "" then headers.Cookie = saved .. "; " .. headers.Cookie end
    else
        headers.Cookie = saved
    end
    return headers
end

---@param url string
---@param headers table|nil
---@param cb fun(raw: string|nil, err: string|nil, res: table|nil)
---@return HttpJob
local function get(url, headers, cb, uncached)
    headers = headers or {}
    -- 默认 UA 会被收藏接口挂住，网页 UA 才能回包。
    if not headers["User-Agent"] then headers["User-Agent"] = "Mozilla/5.0" end
    headers["User-Agent-PC"] = "PCKuaikan/1.0.0/100000(Mac;10.15.7;Chrome;pckuaikan;1800*2880;564)"
    return Request.get(url, opts({ headers = headers, cache_ttl = (uncached or headers.Cookie) and 0 or nil }), cb)
end

--- 登录会话只访问官网和微信开放平台；第三方域绝不附带快看 Cookie。
---@param url string
---@param cookie string|nil
---@param cb fun(raw: string|nil, err: any, res: table|nil)
---@param fields table|nil POST 表单；nil 为 GET
---@return HttpJob
function Client.loginRequestAsync(url, cookie, cb, fields, method)
    method = method or (fields and "POST" or "GET")
    local official = url:sub(1, #HOST + 1) == HOST .. "/"
    if not official and not url:match("^https://open%.weixin%.qq%.com/")
        and not url:match("^https://long%.open%.weixin%.qq%.com/") then
        return require("source.base").defer(cb, nil, _("登录响应无效"))
    end
    local headers = {
        ["User-Agent"] = "Mozilla/5.0",
        ["User-Agent-PC"] = "PCKuaikan/1.0.0/100000(Mac;10.15.7;Chrome;pckuaikan;1800*2880;564)",
        Referer = official and Client.LOGIN_URL or "https://open.weixin.qq.com/",
    }
    if official and cookie and cookie ~= "" then headers.Cookie = cookie end
    local options = opts({ headers = headers, cache_ttl = 0,
        timeout = math.min(require("http.timeout").net(1), 30) })
    local callback = require("ui.guard").wrap("kuaikan login", cb)
    if method == "DELETE" and official then
        options.url, options.method, options.body = url, method, ""
        return Request.request(options, function(res, err)
            callback(not err and res and res.body or nil, err, res)
        end)
    end
    if method ~= "GET" and method ~= "POST" then
        return require("source.base").defer(cb, nil, _("响应无效"))
    end
    if fields then
        if not official then return require("source.base").defer(cb, nil, _("登录响应无效")) end
        options.content_type = "application/x-www-form-urlencoded"
        return Request.post(url, Text.formEncode(fields), options, callback)
    end
    return Request.get(url, options, callback)
end

--- 账号校验响应；登录失效与临时网络错误分开。
---@param raw string|nil
---@param err any
---@param res table|nil
---@return { user_id: string }|nil
---@return string|nil
---@return boolean|nil
function Client.accountResponse(raw, err, res)
    local status = res and tonumber(res.code)
    local location = Request.header(res, "Location")
    if status == 401 or (status and status >= 300 and status < 400
        and type(location) == "string"
        and (location == "/webs/loginh" or location:sub(1, #"/webs/loginh?") == "/webs/loginh?"
            or location == Client.LOGIN_URL or location:sub(1, #Client.LOGIN_URL + 1) == Client.LOGIN_URL .. "?")) then
        return nil, _("快看登录已失效，请重新登录"), true
    end
    if not raw or raw == "" or err then return nil, err and tostring(err) or _("请求失败") end
    local ok, wire = pcall(JSON.decode, raw)
    if not ok then return nil, _("登录响应无效") end
    local account, reason = Mapper.account(wire)
    if reason == "unauthorized" then return nil, _("快看登录已失效，请重新登录"), true end
    if not account then return nil, _("登录响应无效") end
    return account
end

---@param keyword string
---@param cb fun(books: Book[]|nil, err: string|nil)
---@return HttpJob
function Client.searchAsync(keyword, cb)
    local url = HOST .. "/search/web/complex?f=3&q=" .. Text.urlEncode(keyword)
    return get(url, nil, function(raw, err)
        if not raw or raw == "" then cb(nil, err and tostring(err) or _("请求失败")); return end
        local ok, wire = pcall(JSON.decode, raw)
        if not ok then cb(nil, _("请求失败")); return end
        local books = Mapper.search(wire)
        if not books then cb(nil, _("请求失败")); return end
        cb(books)
    end)
end

---@param cb fun(books: Book[]|nil, err: string|nil)
---@param cookie string|nil 本轮已校验的 Cookie；缺省取当前配置
---@return { cancel: fun() }
function Client.favAsync(cb, cookie)
    if cookie == nil then cookie = require("utils.settings").getSource("kuaikan").cookie or "" end
    local cancelled, active = false, nil
    local offset, collected, seen = 0, {}, {}
    local function nextPage()
        local pending = true
        local job = get(HOST .. "/v2/pweb/fav/topics?since=" .. offset .. "&limit=20",
            withCookie({ Referer = HOST .. "/webs/booklist" }, cookie), function(raw, err)
                pending, active = false, nil
                if cancelled then return end
                if not raw or raw == "" or err then cb(nil, err and tostring(err) or _("请求失败")); return end
                local ok, wire = pcall(JSON.decode, raw)
                if not ok then cb(nil, _("响应无效")); return end
                local books, total = Mapper.fav(wire)
                if not books or not total or offset + #books > total or (#books == 0 and offset < total) then
                    cb(nil, _("响应无效")); return
                end
                local added = 0
                for _index, book in ipairs(books) do
                    if not seen[book.stable_id] then
                        seen[book.stable_id] = true
                        collected[#collected + 1] = book
                        added = added + 1
                    end
                end
                if #books > 0 and added == 0 then cb(nil, _("响应无效")); return end
                offset = offset + #books
                if offset >= total then cb(collected); return end
                nextPage()
            end, true)
        if pending then active = job end
    end
    nextPage()
    return { cancel = function()
        cancelled = true
        if active then active.cancel() end
    end }
end

--- 有稳定账号身份的登录态默认同步，真实有效性由请求前的账号校验确认。
---@return boolean
function Client.hasAccount()
    local cfg = require("utils.settings").getSource("kuaikan")
    return type(cfg.cookie) == "string" and cfg.cookie ~= ""
        and type(cfg.user_id) == "string" and cfg.user_id ~= ""
end

---@class KuaikanSync
---@field cookie string
---@field previous_cookie string|nil
---@field user_id string|nil
---@field revision integer
---@field writing boolean
---@field cancelled boolean|nil
---@field job CancelHandle|nil
---@field push_error string|nil
local Sync = {}
Sync.__index = Sync

---@param writing boolean|nil
---@return KuaikanSync
function Client.newSync(writing)
    local cfg = require("utils.settings").getSource("kuaikan")
    return setmetatable({
        cookie = cfg.cookie or "", previous_cookie = cfg.cookie, user_id = cfg.user_id,
        revision = Client.login_revision, writing = writing == true,
    }, Sync)
end

---@return boolean
function Sync:current()
    local cfg = require("utils.settings").getSource("kuaikan")
    return not self.cancelled and self.revision == Client.login_revision
        and cfg.cookie == self.previous_cookie and cfg.user_id == self.user_id
        and (not self.writing or self.user_id ~= nil)
end

function Sync:cancel()
    self.cancelled = true
    if self.job then self.job:cancel(); self.job = nil end
end

---@param path string
---@param cb fun(raw: string|nil, err: any, res: table|nil)
---@param fields table|nil
---@param method string|nil
---@param anonymous boolean|nil
function Sync:request(path, cb, fields, method, anonymous)
    if not self:current() then cb(nil, _("登录状态已变化，请重试")); return end
    local pending = true
    local job = Client.loginRequestAsync(HOST .. path, anonymous and "" or self.cookie, function(raw, err, res)
        pending, self.job = false, nil
        if self.cancelled then return end
        if not self:current() then cb(nil, _("登录状态已变化，请重试")); return end
        cb(raw, err, res)
    end, fields, method)
    if pending then self.job = job end
end

---@param cb fun(account: table|nil, err: string|nil)
function Sync:checkAsync(cb)
    if not require("ui/network/manager"):isConnected() then
        return require("source.base").defer(cb, nil, _("网络不可用，请先连接 Wi-Fi"))
    end
    self:request("/v2/pweb/user_info/get", function(raw, err, res)
        local account, reason, expired = Client.accountResponse(raw, err, res)
        if not account then
            if expired then require("source.auth").expire("kuaikan", reason) end
            cb(nil, reason)
        elseif self.user_id and tostring(self.user_id) ~= account.user_id then
            cb(nil, _("登录状态已变化，请重试"))
        else
            require("source.auth").ok("kuaikan")
            cb(account)
        end
    end)
    return self
end

---@param cb fun(books: Book[]|nil, err: string|nil)
---@return KuaikanSync
function Sync:shelfSyncAsync(cb)
    if not self:current() then cb(nil, _("登录状态已变化，请重试")); return self end
    local pending = true
    local job = Client.favAsync(function(books, err)
        pending, self.job = false, nil
        if self.cancelled then return end
        if not self:current() then cb(nil, _("登录状态已变化，请重试")); return end
        cb(books, err)
    end, self.cookie)
    if pending then self.job = job end
    return self
end

---@param raw string|nil
---@param err any
---@return table|nil
---@return string|nil
local function syncResponse(raw, err)
    if err or not raw or raw == "" then return nil, err and tostring(err) or _("请求失败") end
    local ok, wire = pcall(JSON.decode, raw)
    if not ok or type(wire) ~= "table" then return nil, _("响应无效") end
    if tonumber(wire.code) ~= 200 then
        return nil, type(wire.message) == "string" and wire.message ~= "" and wire.message or _("请求失败")
    end
    return wire
end

---@param stable_id string
---@param adding boolean
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return KuaikanSync
function Sync:changeShelfAsync(stable_id, adding, cb)
    local function finish(ok, err)
        if not ok then self.push_error = self.push_error or err or _("请求失败") end
        cb(ok, err)
    end
    if not self.writing then finish(nil, _("登录状态已变化，请重试")); return self end
    self:request("/v1/aegis/api/web/challenge?callback=callback_1", function(raw, err, res)
        local challenge = not err and raw and cookieOf(res)
        if not challenge then finish(nil, err and tostring(err) or _("响应无效")); return end
        self.cookie = withCookie({ Cookie = "kk_s_t=" .. challenge }, self.cookie).Cookie
        local path = "/web/topic/" .. Text.urlEncode(stable_id) .. "/fav?answer=" .. Text.urlEncode(Client.answer(challenge))
        self:request(path, function(body, write_err)
            local wire, reason = syncResponse(body, write_err)
            if not wire then finish(nil, reason); return end
            self:shelfSyncAsync(function(books, read_err)
                if not books then finish(nil, read_err); return end
                local found = false
                for _index, book in ipairs(books) do
                    if book.stable_id == stable_id then found = true; break end
                end
                if found ~= adding then finish(nil, _("快看收藏变更尚未确认")); return end
                finish(true)
            end)
        end, adding and {} or nil, adding and "POST" or "DELETE")
    end, nil, nil, true)
    return self
end

function Sync:addToShelfAsync(stable_id, cb)
    return self:changeShelfAsync(stable_id, true, cb)
end

function Sync:removeFromShelfAsync(stable_id, cb)
    return self:changeShelfAsync(stable_id, false, cb)
end

--- history.read_count 是已读话数，不是章内图片数。
---@param stable_id string
---@param cb fun(comic_id: string|nil, err: string|nil)
---@return KuaikanSync
function Sync:historyAsync(stable_id, cb)
    local offset, seen = 0, {}
    local function nextPage()
        self:request("/v2/pweb/read/history/list?since=" .. offset .. "&limit=20", function(raw, err)
            local wire, reason = syncResponse(raw, err)
            if not wire then cb(nil, reason); return end
            local data = wire.data
            local rows = type(data) == "table" and data.topics
            local total = type(data) == "table" and data.total
            if type(rows) ~= "table" or type(total) ~= "number" or total < 0 or total % 1 ~= 0
                or offset + #rows > total or #rows == 0 and offset < total then
                cb(nil, _("响应无效")); return
            end
            local added = 0
            for _index, row in ipairs(rows) do
                if type(row) ~= "table" or row.topic_id == nil or row.comic_id == nil then
                    cb(nil, _("响应无效")); return
                end
                local key = tostring(row.topic_id)
                if not seen[key] then seen[key], added = true, added + 1 end
                if key == stable_id then cb(tostring(row.comic_id)); return end
            end
            if #rows > 0 and added == 0 then cb(nil, _("响应无效")); return end
            offset = offset + #rows
            if offset >= total then cb(nil); return end
            nextPage()
        end)
    end
    nextPage()
    return self
end

---@param record table
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return KuaikanSync
function Sync:reportProgressAsync(record, cb)
    if not self.writing then cb(nil, _("登录状态已变化，请重试")); return self end
    self:request("/v2/pweb/read/history/report", function(raw, err)
        local wire, reason = syncResponse(raw, err)
        if not wire then cb(nil, reason); return end
        self:historyAsync(tostring(record.topic_id), function(comic_id, read_err)
            if read_err then cb(nil, read_err)
            elseif comic_id ~= tostring(record.comic_id) then cb(nil, _("快看进度变更尚未确认"))
            else cb(true) end
        end)
    end, { view_rate = JSON.encode({ record }) })
    return self
end

function Client.homeAsync(cb)
    return get(HOST .. "/v2/pweb/home", nil, function(raw, err)
        if not raw or raw == "" then cb(nil, err and tostring(err) or _("请求失败")); return end
        local ok, wire = pcall(JSON.decode, raw)
        if not ok then cb(nil, _("请求失败")); return end
        local books = Mapper.home(wire)
        if not books then cb(nil, _("请求失败")); return end
        cb(books)
    end)
end

---@param node string
---@param page integer
---@param cb fun(books: Book[]|nil, err: string|nil, more: boolean|nil, groups: StoreChipGroup[]|nil)
function Client.storeAsync(node, page, cb)
    local tag, region, pays, state, sort = Mapper.storeNode(node):match("^(%d+):(%d+):(%d+):(%d+):(%d+)$")
    local url = HOST .. "/search/mini/topic/multi_filter?page=" .. page
        .. "&size=48&tag_id=" .. tag .. "&label_dimension_origin=" .. region
        .. "&pay_status=" .. pays .. "&update_status=" .. state .. "&sort=" .. sort
    return get(url, nil, function(raw, err)
        if not raw or raw == "" then cb(nil, err and tostring(err) or _("请求失败")); return end
        local ok, wire = pcall(JSON.decode, raw)
        if not ok then cb(nil, _("响应无效")); return end
        local books, groups, more = Mapper.store(wire, node, page)
        if not books then cb(nil, _("响应无效")); return end
        cb(books, nil, more, groups)
    end)
end

---@param stable_id string
---@param cb fun(page: table|nil, err: string|nil)
---@return HttpJob
function Client.topicAsync(stable_id, cb)
    local url = HOST .. "/web/topic/" .. Text.urlEncode(stable_id) .. "/"
    return get(url, { Referer = HOST .. "/" }, function(raw, err)
        if not raw or raw == "" then cb(nil, err and tostring(err) or _("请求失败")); return end
        local page = Page.topic(raw)
        if not page then cb(nil, _("漫画目录为空")); return end
        cb(page)
    end)
end

--- 一话的页图。锁定的话返回「本章未购买」。
---@param comic_id string
---@param cb fun(urls: string[]|nil, err: string|nil)
---@return HttpJob
function Client.imagesAsync(comic_id, cb)
    local state = { cancelled = false, job = nil }
    local cfg = require("utils.settings").getSource("kuaikan")
    local saved_cookie, saved_id, logged_in = cfg.cookie or "", cfg.user_id, cfg.logged_in == true
    local challenged = false
    local challenge = get(HOST .. "/v1/aegis/api/web/challenge?callback=callback_1", nil, function(_body, err, res)
        challenged = true
        if state.cancelled then return end
        state.job = nil
        local cookie = cookieOf(res)
        if not cookie then cb(nil, err and tostring(err) or _("请求失败")); return end
        local answer = Client.answer(cookie)
        local url = HOST .. "/v2/pweb/comic/" .. comic_id .. "?source=&answer=" .. Text.urlEncode(answer)
        local loaded = false
        local image_job = get(url, withCookie({
            Cookie = "kk_s_t=" .. cookie,
            Referer = HOST .. "/webs/comic-next/" .. comic_id,
            width = "564",
        }, saved_cookie), function(raw, image_err)
            loaded = true
            if state.cancelled then return end
            state.job = nil
            if not raw or raw == "" then cb(nil, image_err and tostring(image_err) or _("请求失败")); return end
            local ok, wire = pcall(JSON.decode, raw)
            if not ok then cb(nil, _("请求失败")); return end
            local urls, locked = Mapper.images(wire)
            if locked == "locked" then
                if not logged_in then cb(nil, _("本章未购买")); return end
                local checked = false
                local account_job = Client.loginRequestAsync(Client.ACCOUNT_URL, saved_cookie, function(account_raw, account_err, account_res)
                    checked = true
                    if state.cancelled then return end
                    state.job = nil
                    local account, reason, expired = Client.accountResponse(account_raw, account_err, account_res)
                    if expired then
                        local current = require("utils.settings").getSource("kuaikan")
                        if current.cookie == saved_cookie and current.user_id == saved_id then
                            require("source.auth").expire("kuaikan", reason)
                        else
                            reason = _("登录状态已变化，请重试")
                        end
                    end
                    cb(nil, account and _("本章未购买") or reason)
                end)
                if not checked then state.job = account_job end
                return
            end
            if not urls then cb(nil, _("章节图片解析失败")); return end
            cb(urls)
        end)
        if not loaded then state.job = image_job end
    end, true)
    if not challenged then state.job = challenge end
    return { cancel = function()
        state.cancelled = true
        if state.job then state.job.cancel() end
    end }
end

---@param comic_id string
---@param offset integer
---@param cb fun(items: table[]|nil, err: string|nil, pages: integer|nil, pagination: {total: integer, max_idx: integer, more: boolean}|nil)
function Client.commentPageAsync(comic_id, offset, cb)
    local url = HOST .. "/v2/comments/comic/" .. Text.urlEncode(comic_id)
        .. "/order/score?offset=" .. offset .. "&limit=50&total=true"
    return get(url, { Referer = HOST .. "/webs/comic-next/" .. Text.urlEncode(comic_id) }, function(raw, err)
        if not raw or raw == "" then cb(nil, err and tostring(err) or _("请求失败")); return end
        local ok, wire = pcall(JSON.decode, raw)
        if not ok then cb(nil, _("响应无效")); return end
        local items, total = Mapper.comments(wire)
        if not items or not total then cb(nil, _("快看漫画书评加载失败")); return end
        local next_idx = offset + #wire.data.comments
        cb(items, nil, math.max(1, math.ceil(total / 50)), {
            total = total, max_idx = next_idx, more = #wire.data.comments > 0 and next_idx < total,
        })
    end)
end

--- 话题页评论。目标是话题信息里的 first_comic_id，按热度取第一页 50 条。
---@param stable_id string
---@param cb fun(items: table[]|nil, err: string|nil, pages: integer|nil)
---@return { cancel: fun() }
function Client.commentsAsync(stable_id, cb)
    local state = { cancelled = false, job = nil }
    local loaded = false
    local topic_job = Client.topicAsync(stable_id, function(page, err)
        loaded = true
        if state.cancelled then return end
        state.job = nil
        if not page then cb(nil, err or _("快看漫画书评加载失败")); return end
        local info = page.info
        local comic_id = type(info) == "table" and info.first_comic_id or nil
        local id = (type(comic_id) == "number" or type(comic_id) == "string") and tostring(comic_id) or ""
        if id == "" or id == "0" then cb(nil, _("快看漫画书评加载失败")); return end
        local fetched = false
        local comment_job = Client.commentPageAsync(id, 0, function(items, get_err, pages)
            fetched = true
            if state.cancelled then return end
            state.job = nil
            cb(items, get_err, pages)
        end)
        if not fetched then state.job = comment_job end
    end)
    if not loaded then state.job = topic_job end
    return { cancel = function()
        state.cancelled = true
        if state.job and state.job.cancel then state.job.cancel() end
    end }
end

return Client
