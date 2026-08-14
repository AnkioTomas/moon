--[[--
微信读书协议客户端：只返回 wire，不做领域转换。

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

--- 拉取 userInfo 探测会话是否有效。
---@return table|nil, string|nil
function Client:ping()
    local vid = Auth.userVid()
    if not vid then
        return nil, _("请先扫码登录微信读书")
    end
    local data, err = Auth.webApiGet("/api/userInfo?userVid=" .. tostring(vid))
    if not data then
        return nil, err
    end
    return data
end

--- 同步书架 wire。
---@return table|nil, string|nil
function Client:shelfSync()
    local data, err = Auth.webApiGet("/web/shelf/sync?" .. encodeQuery({
        synckey = 0,
        teenmode = 0,
    }))
    if not data then
        data, err = Auth.apiGet("/shelf/sync")
    end
    if not data then
        local vid = Auth.userVid()
        if vid then
            data, err = Auth.apiGet("/shelf/friendCommon?" .. encodeQuery({ userVid = vid }))
        end
    end
    return data, err
end

--- 最近阅读书籍 wire。
---@param limit number|nil
---@return table|nil, string|nil
function Client:recentBooks(limit)
    limit = tonumber(limit) or 8
    return Auth.webApiGet("/api/storyfeed/getRecentBooks?count=" .. tostring(limit))
end

--- 书城搜索。
---@param keyword string
---@param count number|nil
---@param scope number|nil
---@return table|nil, string|nil
function Client:search(keyword, count, scope)
    keyword = tostring(keyword or "")
    if keyword == "" then
        return { books = {} }
    end
    count = tonumber(count) or 20
    scope = tonumber(scope) or 10
    local data, err = Auth.apiGet("/store/search?" .. encodeQuery({
        keyword = keyword,
        count = count,
        scope = scope,
        v = 2,
    }))
    if not data then
        data, err = Auth.apiPost("/store/search", {
            keyword = keyword,
            count = count,
            scope = scope,
        })
    end
    return data, err
end

--- 书籍详情 wire。
---@param bookId string
---@return table|nil, string|nil
function Client:bookInfo(bookId)
    bookId = tostring(bookId or "")
    return Auth.webApiGet("/web/book/info?" .. encodeQuery({ bookId = bookId }))
end

--- 章节目录 wire。
---@param bookId string
---@return table|nil, string|nil
function Client:chapterInfos(bookId)
    bookId = tostring(bookId or "")
    return Auth.webApiPost("/web/book/chapterInfos", {
        bookIds = { bookId },
    })
end

--- 拉取阅读进度 wire。
---@param bookId string
---@return table|nil, string|nil
function Client:getProgress(bookId)
    bookId = tostring(bookId or "")
    local data, err = Auth.webApiGet("/web/book/getProgress?" .. encodeQuery({
        bookId = bookId,
        _ = tostring(os.time() * 1000),
    }))
    if not data then
        data, err = Auth.apiGet("/book/getprogress?" .. encodeQuery({ bookId = bookId }))
    end
    return data, err
end

--- 上传阅读进度。
---@param bookId string
---@param progress_percent integer 0..100
---@param chapter_uid string|number|nil
---@return table|nil, string|nil
function Client:putProgress(bookId, progress_percent, chapter_uid)
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
    local raw, err = Auth.webPost("https://i.weread.qq.com/book/progress", JSON.encode(body))
    if not raw then
        logger.warn("weread putProgress", err)
        return nil, err or _("进度上传失败")
    end
    return { ok = true }
end

--- 当前会话请求头（封面下载等复用）。
---@return table
function Client.sessionHeaders()
    return Auth.sessionHeaders()
end

return Client
