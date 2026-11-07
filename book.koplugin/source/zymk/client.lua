--[[--
知音漫客网页接口。

搜索是本站 `/apinew/getsortlist/`，分类库来自 `/apinew/allComic/`。
漫画页的章节链接 301 到看漫画，目录和页图都在那边；整书评论来自官方公共评论服务。
公开阅读不附带账号凭证；账号请求只向知音漫客自己的接口提交。

@module source.zymk.client
--]]

require("l10n").apply()
local JSON = require("json")
local Mapper = require("source.zymk.mapper")
local Page = require("source.zymk.page")
local Request = require("http.request")
local Text = require("utils.text")
local _ = require("gettext")
local Browse = require("source.browse")
local SourceBase = require("source.base")

local Client = {}

local HOST = "https://www.zymk.cn"
local READER = "https://www.kanman.com"
Client.LOGIN_URL = HOST .. "/login.htm"

---@param path string
---@param fields table
---@param cb fun(data: table|nil, err: string|nil)
---@return HttpJob
function Client.authAsync(path, fields, cb)
    return Request.post(HOST .. path, Text.formEncode(fields), {
        timeout = require("http.timeout").net(1),
        content_type = "application/x-www-form-urlencoded; charset=UTF-8",
        headers = {
            Origin = HOST,
            Referer = Client.LOGIN_URL,
            ["X-Requested-With"] = "XMLHttpRequest",
        },
        allow_redirects = false,
    }, function(raw, err)
        if err or not raw then cb(nil, err and tostring(err) or _("请求失败")); return end
        local decoded, wire = pcall(JSON.decode, raw)
        if not decoded or type(wire) ~= "table" or tonumber(wire.status) == nil then
            cb(nil, _("登录响应无效"))
        elseif path == "/apinew/sendsms/" and tonumber(wire.status) == 0 then
            cb({ sent = true })
        elseif path == "/apinew/sendsms/" and (tonumber(wire.status) == 1031 or tonumber(wire.status) == 1028) then
            local captcha = Mapper.captcha(wire.data)
            cb(captcha, not captcha and _("图形验证码加载失败") or nil)
        elseif tonumber(wire.status) ~= 0 then
            cb(nil, type(wire.msg) == "string" and wire.msg ~= "" and wire.msg or _("登录失败"))
        elseif type(wire.data) ~= "table" then
            cb(nil, _("登录响应无效"))
        else
            cb(wire.data)
        end
    end)
end

---@param account ZymkAccount|nil
---@param cb fun(books: Book[]|nil, err: string|nil)
---@return { cancel: fun() }
function Client.shelfAsync(account, cb)
    local Settings = require("utils.settings")
    if not Mapper.account(account) or require("source.auth").expired("zymk") then
        return SourceBase.defer(cb, nil, _("请先登录知音漫客"))
    end
    if Settings.getSource("zymk").account ~= account then
        return SourceBase.defer(cb, nil, _("登录状态已变化，请重试"))
    end
    if not require("ui/network/manager"):isConnected() then
        return SourceBase.defer(cb, nil, _("网络不可用，请先连接 Wi-Fi"))
    end
    local fields = { type = account.type, openid = account.openid }
    local cancelled = false
    local job = Client.authAsync("/apinew/getuserrecord/", fields, function(data, err)
        if cancelled then return end
        if Settings.getSource("zymk").account ~= account then
            cb(nil, _("登录状态已变化，请重试")); return
        end
        local books = data and Mapper.shelf(data)
        cb(books, err or (not books and _("响应无效") or nil))
    end)
    return { cancel = function()
        cancelled = true
        job.cancel()
    end }
end

---@param url string
---@param cb fun(body: string|nil, err: any, res: table|nil)
---@return HttpJob
local function get(url, cb)
    return Request.get(url, { timeout = require("http.timeout").net(1) }, cb)
end

---@param res table|nil
---@return string|nil
local function comicId(res)
    local code = res and tonumber(res.code)
    if code ~= 301 and code ~= 302 and code ~= 303 and code ~= 307 and code ~= 308 then return nil end
    local location = Request.header(res, "location")
    if type(location) ~= "string" then return nil end
    return location:match("^https?://www%.kanman%.com/(%d+)/")
end

---@param keyword string
---@param cb fun(books: Book[]|nil, err: string|nil)
---@return HttpJob
function Client.searchAsync(keyword, cb)
    return Browse.pages(function(page, done)
        local url = HOST .. "/apinew/getsortlist/?key=" .. Text.urlEncode(keyword) .. "&page=" .. page
        return get(url, function(raw, err)
            if not raw or raw == "" then done(nil, err and tostring(err) or _("请求失败")); return end
            local ok, wire = pcall(JSON.decode, raw)
            if not ok then done(nil, _("响应无效")); return end
            local books = Mapper.list(wire)
            if not books then done(nil, _("响应无效")); return end
            local total_page = tonumber(wire.data.page.total_page)
            done(books, nil, not total_page or page < total_page)
        end)
    end, 200, {}, function(result, err)
        cb(result and result.data or nil, err)
    end)
end

---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client.libraryAsync(cb)
    local cancelled, active, pending = false, nil, true
    local job = get(HOST .. "/sort/all.html", function(html, err)
        pending = false
        if cancelled then return end
        active = nil
        local filters = html and Page.filters(html)
        if not filters then cb(nil, err and tostring(err) or _("响应无效")); return end
        local loading = true
        local inner = get(HOST .. "/apinew/allComic/", function(raw, list_err)
            loading = false
            if cancelled then return end
            active = nil
            if not raw then cb(nil, list_err and tostring(list_err) or _("请求失败")); return end
            local ok, wire = pcall(JSON.decode, raw)
            if not ok or type(wire) ~= "table" or tonumber(wire.status) ~= 0
                or type(wire.data) ~= "table" then cb(nil, _("响应无效")); return end
            cb({ filters = filters, rows = wire.data })
        end)
        if loading then active = inner end
    end)
    if pending then active = job end
    return { cancel = function()
        cancelled = true
        if active then active.cancel() end
    end }
end

--- 整本漫画评论，ssidType=0；不是章评或段评。该服务成功码为 1。
---@param stable_id string
---@param page integer
---@param cb fun(page: table|nil, err: string|nil)
---@return HttpJob
function Client.reviewsAsync(stable_id, page, cb)
    local cancelled = false
    local query = Text.formEncode({
        platformname = "pc", appid = 11, appId = 11,
        ssid = stable_id, ssidtype = 0, ssidType = 0,
        page = page, pagesize = 20, filter = 1, contenttype = 0, relateid = 0, fatherid = 0,
    })
    local job = get("https://community-hots.321mh.com/comment/newgets?" .. query, function(raw, err)
        if cancelled then return end
        if not raw then cb(nil, err and tostring(err) or _("请求失败")); return end
        local ok, wire = pcall(JSON.decode, raw)
        if not ok then cb(nil, _("响应无效")); return end
        local result = Mapper.reviews(stable_id, page, wire)
        if not result then cb(nil, _("响应无效")); return end
        cb(result)
    end)
    return { cancel = function()
        cancelled = true
        if job then job.cancel() end
    end }
end

--- 详情页 → 一话跳转 → 看漫画目录。
---@param stable_id string
---@param cb fun(page: { book: Book, chapters: BookChapter[] }|nil, err: string|nil)
---@return { cancel: fun() }
function Client.catalogAsync(stable_id, cb)
    local state = { cancelled = false, job = nil }
    local id = Text.urlEncode(tostring(stable_id))
    local pending = true
    local job = get(HOST .. "/" .. id .. "/", function(raw, err)
        pending = false
        if state.cancelled then return end
        state.job = nil
        local page = raw and Page.detail(raw) or nil
        if not page then cb(nil, err and tostring(err) or _("漫画目录为空")); return end
        local probing = true
        local probe = get(HOST .. "/" .. id .. "/" .. page.chapter_file .. ".html", function(_body, probe_err, res)
            probing = false
            if state.cancelled then return end
            state.job = nil
            local comic_id = comicId(res)
            if not comic_id then cb(nil, probe_err and tostring(probe_err) or _("漫画目录为空")); return end
            local listing = true
            local list_job = get(READER .. "/api/getchapterlist?comic_id=" .. comic_id, function(list_raw, list_err)
                listing = false
                if state.cancelled then return end
                state.job = nil
                if not list_raw or list_raw == "" then cb(nil, list_err and tostring(list_err) or _("请求失败")); return end
                local ok, wire = pcall(JSON.decode, list_raw)
                local chapters = ok and type(wire) == "table" and tonumber(wire.status) == 0
                    and Mapper.chapters(comic_id, wire.data) or nil
                local book = Mapper.detail(page, stable_id)
                if not chapters or not book then cb(nil, _("响应无效")); return end
                cb({ book = book, chapters = chapters })
            end)
            if listing then state.job = list_job end
        end)
        if probing then state.job = probe end
    end)
    if pending then state.job = job end
    return { cancel = function()
        state.cancelled = true
        if state.job then state.job.cancel() end
    end }
end

--- uid 是 `看漫画id/chapter_newid`。要 JPEG，阅读器不解 webp。
---@param uid string
---@param cb fun(urls: string[]|nil, err: string|nil)
---@return { cancel: fun() }
function Client.imagesAsync(uid, cb)
    local comic_id, newid = tostring(uid):match("^(%d+)/(.+)$")
    if not comic_id or not newid then
        return SourceBase.defer(cb, nil, _("章节图片解析失败"))
    end
    local url = READER .. "/api/getchapterinfov2?product_id=1&productname=kmh&platformname=pc&comic_id="
        .. comic_id .. "&chapter_newid=" .. Text.urlEncode(newid) .. "&isWebp=0&quality=middle"
    local state = { cancelled = false, job = nil }
    state.job = get(url, function(raw, err)
        if state.cancelled then return end
        if not raw or raw == "" then cb(nil, err and tostring(err) or _("请求失败")); return end
        local ok, wire = pcall(JSON.decode, raw)
        if not ok then cb(nil, _("请求失败")); return end
        local urls, locked = Mapper.images(wire)
        if locked == "locked" then cb(nil, _("本章未购买")); return end
        if not urls then cb(nil, _("章节图片解析失败")); return end
        cb(urls)
    end)
    return { cancel = function()
        state.cancelled = true
        if state.job then state.job.cancel() end
    end }
end

return Client
