--[[--
知乎盐选网页接口。

榜单匿名可用。搜索是 `/api/v4/search_v3?t=km_general`，没有登录态会被风控。
正文先看 `manuscript/simple` 的 `is_fold`，没折叠再读章节页里的 `manuscript`。

@module source.zhihu.client
--]]

require("l10n").apply()
local JSON = require("json")
local Mapper = require("source.zhihu.mapper")
local Page = require("source.zhihu.page")
local Request = require("http.request")
local Text = require("utils.text")
local _ = require("gettext")

local Client = {}

local API = "https://api.zhihu.com"
local WEB = "https://www.zhihu.com"

---@param headers table|nil
---@return table
local function opts(headers)
    return { timeout = require("http.timeout").net(1), headers = headers }
end

--- 搜索没有登录态会被风控。Cookie 存在 settings，跟其它源一样随请求带上。
---@param headers table|nil
---@return table|nil
local function withCookie(headers)
    local cfg = require("utils.settings").getSource("zhihu")
    local saved = type(cfg.cookie) == "string" and cfg.cookie or ""
    if saved == "" then return headers end
    headers = headers or {}
    if not headers.Cookie then headers.Cookie = saved end
    return headers
end

---@param url string
---@param headers table|nil
---@param cb fun(body: string|nil, err: any)
---@return HttpJob
local function get(url, headers, cb)
    return Request.get(url, opts(withCookie(headers)), function(body, err)
        cb(body, err)
    end)
end

---@param raw string|nil
---@return table|nil
local function decode(raw)
    if not raw or raw == "" then return nil end
    local ok, wire = pcall(JSON.decode, raw)
    if not ok or type(wire) ~= "table" then return nil end
    return wire
end

---@param keyword string
---@param cb fun(books: Book[]|nil, err: string|nil)
---@return HttpJob
function Client.searchAsync(keyword, cb)
    local url = WEB .. "/api/v4/search_v3?t=km_general&q=" .. Text.urlEncode(keyword)
        .. "&correction=1&offset=0&limit=20&lc_idx=0&show_all_topics=0&search_source=Normal"
    return get(url, { ["X-API-Version"] = "3.0.91", ["X-App-Za"] = "OS=Web" }, function(raw, err)
        local books = Mapper.search(decode(raw))
        if not books then cb(nil, err and tostring(err) or _("请求失败")); return end
        cb(books)
    end)
end

---@param cb fun(books: Book[]|nil, err: string|nil)
---@return HttpJob
function Client.browseAsync(cb)
    local url = API .. "/km-vip-zhihu-web/vip_tab/svip_story?modules=billboard,today_read,feed_card"
    return get(url, nil, function(raw, err)
        local books = Mapper.feed(decode(raw))
        if not books then cb(nil, err and tostring(err) or _("请求失败")); return end
        cb(books)
    end)
end

---@param stable_id string
---@return string|nil
---@return string|nil
local function ids(stable_id)
    return tostring(stable_id):match("^(%d+)/(%d+)$")
end

---@param stable_id string
---@param cb fun(wire: table|nil, err: string|nil)
---@return HttpJob|{ cancel: fun() }
function Client.simpleAsync(stable_id, cb)
    local well, section = ids(stable_id)
    if not well then
        require("ui/uimanager"):nextTick(function() cb(nil, _("请求失败")) end)
        return { cancel = function() end }
    end
    local url = API .. "/remix-web/paid_columns/" .. well .. "/sections/" .. section .. "/manuscript/simple"
    return get(url, nil, function(raw, err)
        local wire = decode(raw)
        if type(wire) ~= "table" or type(wire.section) ~= "table" then
            cb(nil, err and tostring(err) or _("请求失败"))
            return
        end
        cb(wire)
    end)
end

--- 未折叠才去读章节页。折叠按未购买。
---@param stable_id string
---@param cb fun(html: string|nil, err: string|nil)
---@return { cancel: fun() }
function Client.contentAsync(stable_id, cb)
    local state = { cancelled = false, job = nil }
    state.job = Client.simpleAsync(stable_id, function(wire, err)
        if state.cancelled then return end
        if not wire then cb(nil, err); return end
        if wire.is_fold ~= false then cb(nil, _("本章未购买")); return end
        local well, section = ids(stable_id)
        state.job = get(WEB .. "/market/paid_column/" .. well .. "/section/" .. section, nil, function(raw, page_err)
            if state.cancelled then return end
            local html, locked = Page.manuscript(raw)
            if locked == "locked" then cb(nil, _("本章未购买")); return end
            if not html then cb(nil, page_err and tostring(page_err) or _("请求失败")); return end
            cb(html)
        end)
    end)
    return { cancel = function()
        state.cancelled = true
        if state.job and state.job.cancel then state.job.cancel() end
    end }
end

return Client
