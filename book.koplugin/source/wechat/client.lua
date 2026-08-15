--[[--
微信读书协议客户端：只返回 wire，不做领域转换（仅异步）。

@module koplugin.book.source.wechat.client
--]]

local JSON = require("json")
local logger = require("logger")
local Auth = require("source.wechat.auth")
local _ = require("gettext")

local Client = {}
Client.__index = Client

--- 编码 query 表为 application/x-www-form-urlencoded 风格。
---@param tbl table|nil
---@return string
local function encodeQuery(tbl)
    local parts = {}
    for k, v in pairs(tbl or {}) do
        if v ~= nil then
            parts[#parts + 1] = tostring(k) .. "=" .. tostring(v):gsub("[^%w%-_%.~]", function(c)
                return string.format("%%%02X", string.byte(c))
            end)
        end
    end
    return table.concat(parts, "&")
end

--- 构造微信读书客户端实例。
---@param o table|nil
---@return WechatClient
function Client:new(o)
    o = o or {}
    setmetatable(o, self)
    return o
end

--- 是否已登录（有会话）。
---@return boolean
function Client:configured()
    return Auth.hasSession()
end

--- 当前会话请求头（封面下载等复用）。
---@return table
function Client.sessionHeaders()
    return Auth.sessionHeaders()
end

function Client:shelfSyncAsync(cb)
    return Auth.webApiGetAsync("/web/shelf/sync?" .. encodeQuery({
        synckey = 0,
        teenmode = 0,
    }), function(data, err)
        if data then
            cb(data)
            return
        end
        Auth.apiGetAsync("/shelf/sync", function(fallback, fallback_err)
            cb(fallback, fallback_err or err)
        end)
    end)
end

function Client:recentBooksAsync(limit, cb)
    limit = tonumber(limit) or 8
    return Auth.webApiGetAsync("/api/storyfeed/getRecentBooks?count=" .. tostring(limit), cb)
end

function Client:searchAsync(keyword, count, scope, cb)
    keyword = tostring(keyword or "")
    if keyword == "" then
        cb({ books = {} })
        return nil
    end
    count = tonumber(count) or 20
    scope = tonumber(scope) or 10
    return Auth.apiGetAsync("/store/search?" .. encodeQuery({
        keyword = keyword,
        count = count,
        scope = scope,
        v = 2,
    }), function(data, err)
        if data then
            cb(data)
            return
        end
        Auth.apiPostAsync("/store/search", {
            keyword = keyword,
            count = count,
            scope = scope,
        }, function(fallback, fallback_err)
            cb(fallback, fallback_err or err)
        end)
    end)
end

function Client:bookInfoAsync(bookId, cb)
    bookId = tostring(bookId or "")
    return Auth.webApiGetAsync("/web/book/info?" .. encodeQuery({ bookId = bookId }), cb)
end

function Client:chapterInfosAsync(bookId, cb)
    bookId = tostring(bookId or "")
    return Auth.webApiPostAsync("/web/book/chapterInfos", {
        bookIds = { bookId },
    }, cb)
end

function Client:getProgressAsync(bookId, cb)
    bookId = tostring(bookId or "")
    return Auth.webApiGetAsync("/web/book/getProgress?" .. encodeQuery({
        bookId = bookId,
        _ = tostring(os.time() * 1000),
    }), function(data, err)
        if data then
            cb(data)
            return
        end
        Auth.apiGetAsync("/book/getprogress?" .. encodeQuery({ bookId = bookId }), function(fallback, fallback_err)
            cb(fallback, fallback_err or err)
        end)
    end)
end

function Client:putProgressAsync(bookId, progress_percent, chapter_uid, cb)
    bookId = tostring(bookId or "")
    local body = {
        appId = "webapp",
        bookId = bookId,
        progress = progress_percent,
        chapterOffset = 0,
    }
    if chapter_uid then
        body.chapterUid = chapter_uid
    end
    return Auth.webPostAsync("https://i.weread.qq.com/book/progress", JSON.encode(body), nil, function(raw, err)
        if not raw then
            logger.warn("weread putProgress", err)
            cb(nil, err or _("进度上传失败"))
        else
            cb({ ok = true })
        end
    end)
end

return Client
