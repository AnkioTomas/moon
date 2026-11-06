--[[--
快看漫画网页接口。

搜索和首页是 JSON。目录在话题页 HTML 里。页图要先拿挑战接口的 `kk_s_t`，
再按页面脚本的算法算出 `answer`。未登录可以看免费话，收藏列表是空的，所以不推书架。

@module source.kuaikan.client
--]]

require("l10n").apply()
local JSON = require("json")
local Mapper = require("source.kuaikan.mapper")
local Page = require("source.kuaikan.page")
local Request = require("http.request")
local Text = require("utils.text")
local _ = require("gettext")

local Client = {}

local HOST = "https://www.kuaikanmanhua.com"
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
local function withCookie(headers)
    local cfg = require("utils.settings").getSource("kuaikan")
    local saved = type(cfg.cookie) == "string" and cfg.cookie or ""
    if saved == "" then return headers end
    headers = headers or {}
    if type(headers.Cookie) == "string" and headers.Cookie ~= "" then
        headers.Cookie = saved .. "; " .. headers.Cookie
    else
        headers.Cookie = saved
    end
    return headers
end

---@param url string
---@param headers table|nil
---@param cb fun(raw: string|nil, err: string|nil, res: table|nil)
---@return HttpJob
local function get(url, headers, cb)
    headers = withCookie(headers) or {}
    -- 默认 UA 会被收藏接口挂住，网页 UA 才能回包。
    if not headers["User-Agent"] then headers["User-Agent"] = "Mozilla/5.0" end
    return Request.get(url, opts({ headers = headers }), cb)
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
---@return HttpJob
function Client.favAsync(cb)
    return get(HOST .. "/v2/pweb/fav/topics?since=0&limit=20", { Referer = HOST .. "/" }, function(raw, err)
        if not raw or raw == "" then cb(nil, err and tostring(err) or _("请求失败")); return end
        local ok, wire = pcall(JSON.decode, raw)
        if not ok then cb(nil, _("请求失败")); return end
        local books = Mapper.fav(wire)
        if not books then cb(nil, _("请求失败")); return end
        cb(books)
    end)
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
    state.job = get(HOST .. "/v1/aegis/api/web/challenge?callback=callback_1", nil, function(_body, err, res)
        if state.cancelled then return end
        local cookie = cookieOf(res)
        if not cookie then cb(nil, err and tostring(err) or _("请求失败")); return end
        local answer = Client.answer(cookie)
        local url = HOST .. "/v2/pweb/comic/" .. comic_id .. "?source=&answer=" .. Text.urlEncode(answer)
        state.job = get(url, {
            Cookie = "kk_s_t=" .. cookie,
            Referer = HOST .. "/web/comic/" .. comic_id,
        }, function(raw, image_err)
            if state.cancelled then return end
            if not raw or raw == "" then cb(nil, image_err and tostring(image_err) or _("请求失败")); return end
            local ok, wire = pcall(JSON.decode, raw)
            if not ok then cb(nil, _("请求失败")); return end
            local urls, locked = Mapper.images(wire)
            if locked == "locked" then cb(nil, _("本章未购买")); return end
            if not urls then cb(nil, _("章节图片解析失败")); return end
            cb(urls)
        end)
    end)
    return { cancel = function()
        state.cancelled = true
        if state.job then state.job.cancel() end
    end }
end

--- 话题页评论。目标是话题信息里的 first_comic_id，按热度取第一页 50 条。
---@param stable_id string
---@param cb fun(items: table[]|nil, err: string|nil, pages: integer|nil)
---@return { cancel: fun() }
function Client.commentsAsync(stable_id, cb)
    local state = { cancelled = false, job = nil }
    state.job = Client.topicAsync(stable_id, function(page, err)
        if state.cancelled then return end
        if not page then cb(nil, err or _("快看漫画书评加载失败")); return end
        local info = page.info
        local comic_id = type(info) == "table" and info.first_comic_id or nil
        local id = (type(comic_id) == "number" or type(comic_id) == "string") and tostring(comic_id) or ""
        if id == "" or id == "0" then cb(nil, _("快看漫画书评加载失败")); return end
        local url = HOST .. "/v2/comments/comic/" .. Text.urlEncode(id)
            .. "/order/score?offset=0&limit=50&total=true"
        state.job = get(url, { Referer = HOST .. "/web/topic/" .. Text.urlEncode(stable_id) .. "/" }, function(raw, get_err)
            if state.cancelled then return end
            if not raw or raw == "" then cb(nil, get_err and tostring(get_err) or _("请求失败")); return end
            local ok, wire = pcall(JSON.decode, raw)
            if not ok then cb(nil, _("请求失败")); return end
            local items, total = Mapper.comments(wire)
            if not items then cb(nil, _("快看漫画书评加载失败")); return end
            cb(items, nil, (total and total > #items) and 2 or 1)
        end)
    end)
    return { cancel = function()
        state.cancelled = true
        if state.job and state.job.cancel then state.job.cancel() end
    end }
end

return Client
