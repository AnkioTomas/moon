--[[--
知音漫客网页接口。

搜索和发现是本站 `/apinew/getsortlist/`。漫画页只有一话的相对链接，
这个链接 301 到看漫画，目录和页图都在那边。未登录没有可用的书架列表。

@module source.zymk.client
--]]

require("l10n").apply()
local JSON = require("json")
local Mapper = require("source.zymk.mapper")
local Page = require("source.zymk.page")
local Request = require("http.request")
local Text = require("utils.text")
local _ = require("gettext")

local Client = {}

local HOST = "https://www.zymk.cn"
local READER = "https://www.kanman.com"

---@return table
local function opts()
    return { timeout = require("http.timeout").net(1) }
end

---@param url string
---@param cb fun(body: string|nil, err: any, res: table|nil)
---@return HttpJob
local function get(url, cb)
    return Request.get(url, opts(), cb)
end

---@param res table|nil
---@return string|nil
local function comicId(res)
    local code = res and tonumber(res.code)
    if code ~= 301 and code ~= 302 and code ~= 303 and code ~= 307 and code ~= 308 then return nil end
    local location = Request.header(res, "location")
    if type(location) ~= "string" then return nil end
    return location:match("kanman%.com/(%d+)/")
end

---@param keyword string
---@param cb fun(books: Book[]|nil, err: string|nil)
---@return HttpJob
function Client.searchAsync(keyword, cb)
    local url = HOST .. "/apinew/getsortlist/?key=" .. Text.urlEncode(keyword) .. "&page=1"
    return get(url, function(raw, err)
        if not raw or raw == "" then cb(nil, err and tostring(err) or _("请求失败")); return end
        local ok, wire = pcall(JSON.decode, raw)
        if not ok then cb(nil, _("请求失败")); return end
        local books = Mapper.list(wire)
        if not books then cb(nil, _("请求失败")); return end
        cb(books)
    end)
end

---@param cb fun(books: Book[]|nil, err: string|nil)
---@return HttpJob
function Client.browseAsync(cb)
    return get(HOST .. "/apinew/getsortlist/?page=1", function(raw, err)
        if not raw or raw == "" then cb(nil, err and tostring(err) or _("请求失败")); return end
        local ok, wire = pcall(JSON.decode, raw)
        if not ok then cb(nil, _("请求失败")); return end
        local books = Mapper.list(wire)
        if not books then cb(nil, _("请求失败")); return end
        cb(books)
    end)
end

--- 详情页 → 一话跳转 → 看漫画目录。
---@param stable_id string
---@param cb fun(page: { book: Book, chapters: BookChapter[] }|nil, err: string|nil)
---@return { cancel: fun() }
function Client.catalogAsync(stable_id, cb)
    local state = { cancelled = false, job = nil }
    local id = Text.urlEncode(tostring(stable_id))
    state.job = get(HOST .. "/" .. id .. "/", function(raw, err)
        if state.cancelled then return end
        local page = raw and Page.detail(raw) or nil
        if not page then cb(nil, err and tostring(err) or _("漫画目录为空")); return end
        state.job = get(HOST .. "/" .. id .. "/" .. page.chapter_file .. ".html", function(_body, _probe_err, res)
            if state.cancelled then return end
            local comic_id = comicId(res)
            if not comic_id then cb(nil, _("漫画目录为空")); return end
            state.job = get(READER .. "/api/getchapterlist?comic_id=" .. comic_id, function(list_raw, list_err)
                if state.cancelled then return end
                if not list_raw or list_raw == "" then cb(nil, list_err and tostring(list_err) or _("请求失败")); return end
                local ok, wire = pcall(JSON.decode, list_raw)
                local chapters = ok and Mapper.chapters(comic_id, wire.data) or nil
                local book = Mapper.detail(page, stable_id)
                if not chapters or not book then cb(nil, _("漫画目录为空")); return end
                cb({ book = book, chapters = chapters })
            end)
        end)
    end)
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
        require("ui/uimanager"):nextTick(function() cb(nil, _("章节图片解析失败")) end)
        return { cancel = function() end }
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
