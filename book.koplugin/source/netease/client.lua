--[[--
网易云阅读 Web 接口。账号、书架、目录、正文和进度共用电脑端 Cookie。
公开搜索和分类使用官方移动网页 JSON，不向该域名发送电脑端 Cookie。

@module source.netease.client
--]]

local JSON = require("json")
local Mapper = require("source.netease.mapper")
local Request = require("http.request")
local Text = require("utils.text")
local _ = require("l10n").get("source.netease")

local Client = {}
local ORIGIN = "https://yuedu.163.com"
local SHELF_ORIGIN = "https://guofeng.yuedu.163.com"
local PUBLIC = "https://yuedu.3g.163.com"
local SOURCE_ID = "netease"

function Client.loggedIn()
    local cfg = require("utils.settings").getSource(SOURCE_ID)
    return cfg.logged_in == true and type(cfg.cookie) == "string" and cfg.cookie ~= ""
        and not require("source.auth").expired(SOURCE_ID)
end

--- account 是发请求时的已保存 Cookie，回包后与当前保存值比对判断是否换号。
local function opts(origin)
    local cookie = require("utils.settings").getSource(SOURCE_ID).cookie
    return {
        timeout = require("http.timeout").net(1),
        account = cookie,
        jar = require("http.cookie_jar").session(SOURCE_ID, cookie),
        headers = { Referer = (origin or ORIGIN) .. "/" },
    }
end

local function getJson(url, options, cb)
    return Request.get(url, options, function(raw, err)
        if err or not raw then cb(nil, err and tostring(err) or _("请求失败")); return end
        local ok, wire = pcall(JSON.decode, raw)
        if not ok or type(wire) ~= "table" then cb(nil, _("响应无效")); return end
        cb(wire)
    end)
end

--- 只校验，不改当前会话；匿名账号页会重定向至 loginForm.do。
function Client.loginCheckAsync(cookie, cb)
    return Request.get(ORIGIN .. "/myinfor.do", {
        headers = { Cookie = cookie }, timeout = require("http.timeout").net(1),
    }, function(raw, err, res)
        if err or not Mapper.authorized(raw) then
            local location = res and Request.header(res, "Location")
            local status = res and tonumber(res.code)
            local expired = (status and status >= 300 and status < 400
                and location and location:find("/loginForm.do", 1, true) ~= nil)
                or (not err and raw and raw:find("login%-container") ~= nil)
            cb(false, not expired and err and tostring(err)
                or _("网易云阅读登录校验失败，请在浏览器重新登录"), expired == true)
            return
        end
        cb(true)
    end)
end

function Client:shelfSyncAsync(cb)
    if not Client.loggedIn() then return require("source.base").defer(cb, nil, _("未登录网易云阅读")) end
    local cancelled, job = false, nil
    local books, seen = {}, {}
    local options = opts(SHELF_ORIGIN)
    options.cache_ttl = 0
    local function nextPage(page)
        local pending = true
        local current = Request.get(SHELF_ORIGIN .. "/shelf.do?operation=query_current&style=grid&page=" .. page,
            options, function(raw, err)
                pending = false
                if cancelled then return end
                if not raw then cb(nil, err and tostring(err) or _("请求失败")); return end
                local rows, next_page, reason = Mapper.shelfPage(raw, page)
                if not rows then cb(nil, reason); return end
                for _idx, item in ipairs(rows) do
                    if not seen[item.stable_id] then
                        seen[item.stable_id] = true
                        books[#books + 1] = item
                    end
                end
                if next_page then nextPage(next_page); return end
                cb(books)
            end)
        if pending then job = current end
    end
    nextPage(1)
    return { cancel = function()
        cancelled = true
        if job then job:cancel() end
    end }
end

local function changeShelf(url, fields, cb)
    if not Client.loggedIn() then return require("source.base").defer(cb, nil, _("未登录网易云阅读")) end
    local options = opts(SHELF_ORIGIN)
    options.cache_ttl = 0
    return Request.post(SHELF_ORIGIN .. url, fields and Text.formEncode(fields) or "", options, function(raw, err)
        if err then cb(nil, tostring(err)); return end
        local ok, wire = pcall(JSON.decode, raw)
        if not ok or type(wire) ~= "table" then cb(nil, _("响应无效")); return end
        local code = tonumber(wire.resultCode)
        if code == -999 then
            local reason = _("网易云阅读登录已失效")
            if options.account == require("utils.settings").getSource(SOURCE_ID).cookie then
                reason = require("source.auth").expire(SOURCE_ID, reason)
            end
            cb(nil, reason)
            return
        end
        if code ~= 0 then
            require("utils.log").warn("book netease shelf mutation failed", code)
            cb(nil, code == nil and _("响应无效") or _("同步失败"))
            return
        end
        cb(wire)
    end)
end

function Client:addToShelfAsync(stable_id, cb)
    return changeShelf("/subscribe.do", { operation = "addSub", id = stable_id }, cb)
end

function Client:removeFromShelfAsync(stable_id, cb)
    return changeShelf("/shelf.do?operation=unsub&source_uuids=" .. Text.urlEncode(stable_id), nil, cb)
end

function Client.searchAsync(keyword, cb)
    return getJson(PUBLIC .. "/search/book/data.json?key=" .. Text.urlEncode(keyword), {}, function(wire, err)
        if not wire then cb(nil, err); return end
        cb(Mapper.searchBooks(wire))
    end)
end

function Client.categoriesAsync(cb)
    return Request.get(PUBLIC .. "/category", { cache_ttl = 3600 }, function(raw, err)
        if err or not raw then cb(nil, err and tostring(err) or _("请求失败")); return end
        cb(Mapper.categories(raw))
    end)
end

---@param options { channel: string, category: string, sort: string, pay: string, state: string }
---@param page integer
function Client.catalogAsync(options, page, cb)
    local publish = options.channel == "publish"
    local fields = {
        id = options.category == "all" and "" or options.category,
        sort = options.sort == "hot" and (publish and 1 or 2) or (publish and 2 or 1),
        pay = options.pay, page = page,
    }
    if not publish then fields.gender, fields.state = options.channel, options.state end
    local url = PUBLIC .. (publish and "/category/publish/data.json?" or "/category/original/data.json?")
        .. Text.formEncode(fields)
    return getJson(url, {}, function(wire, err)
        if not wire then cb(nil, err); return end
        cb(Mapper.catalog(wire))
    end)
end

function Client.infoAsync(stable_id, cb)
    return getJson(ORIGIN .. "/getBook.do?id=" .. Text.urlEncode(stable_id), opts(), function(wire, err)
        if not wire then cb(nil, err); return end
        if not Mapper.detail(wire) then cb(nil, _("响应无效")); return end
        cb(wire)
    end)
end

---@param chapter { uid?: string, leaf?: boolean, big_content_id?: string }
function Client.contentAsync(stable_id, chapter, cb)
    local url = ORIGIN .. (chapter.leaf == false and "/getChapterContent.do?" or "/getArticleContent.do?")
        .. Text.formEncode({
            sourceUuid = stable_id, articleUuid = chapter.uid, bigContentId = chapter.big_content_id,
        })
    return getJson(url, opts(), function(wire, err)
        if not wire then cb(nil, err); return end
        if tonumber(wire.resultCode) == 1 then cb(nil, _("本章未购买")); return end
        if tonumber(wire.resultCode) ~= 0 then cb(nil, _("请求失败")); return end
        cb(Mapper.content(wire))
    end)
end

function Client.commentsAsync(stable_id, cb)
    local url = ORIGIN .. "/snsComment.do?operation=get&type=2&page=1&id=" .. Text.urlEncode(stable_id)
    return getJson(url, opts(), function(wire, err)
        if not wire then cb(nil, err); return end
        local items, pages = Mapper.comments(wire)
        if not items then cb(nil, _("网易云阅读书评加载失败")); return end
        cb(items, nil, pages)
    end)
end

function Client.putProgressAsync(stable_id, toc, idx, fraction, cb)
    if not Client.loggedIn() then return require("source.base").defer(cb, nil, _("未登录网易云阅读")) end
    local fields = Mapper.readlog(stable_id, toc, idx, fraction, os.time() * 1000)
    if not fields then return require("source.base").defer(cb, nil, _("缺少网易云阅读章节位置")) end
    -- 官网匿名写进度也返回 1；先确认会话，避免把未同步的本地进度标成成功。
    local cancelled, job, pending = false, nil, true
    local options = opts()
    local initial = Client.loginCheckAsync(options.account, function(valid, reason, expired)
        pending = false
        if cancelled then return end
        if not valid then
            if expired and options.account == require("utils.settings").getSource(SOURCE_ID).cookie then
                reason = require("source.auth").expire(SOURCE_ID, _("网易云阅读登录已失效"))
            end
            cb(nil, reason)
            return
        end
        job = Request.post(ORIGIN .. "/addUserReadLog.do", Text.formEncode(fields), options, function(raw, err)
            if cancelled then return end
            if err or tonumber(raw) ~= 1 then
                cb(nil, err and tostring(err) or _("网易云阅读进度保存失败"))
                return
            end
            require("source.auth").ok(SOURCE_ID)
            cb(true)
        end)
    end)
    if pending then job = initial end
    return { cancel = function()
        cancelled = true
        if job then job:cancel() end
    end }
end

return Client
