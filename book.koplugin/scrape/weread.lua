--[[--
微信读书图书搜索

走公开接口 weread.qq.com/web/search/global（无需登录）
返回字段对齐统一格式，便于 UI 复用

@module koplugin.book.scrape.weread
--]]

local JSON = require("json")
local Request = require("http.request")
local socketurl = require("socket.url")
local logger = require("logger")
local _ = require("gettext")

local Weread = {}

local SEARCH_URL = "https://weread.qq.com/web/search/global"
local DEFAULT_COUNT = 10

--- 去首尾空白；nil 视为空字符串。
---@param s any
---@return string
local function trim(s)
    return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local mapBook

--- 搜索微信读书
---@param query string
---@param count number|nil
---@param cb fun(results: table[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Weread.searchAsync(query, count, cb)
    query = (query or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if query == "" then
        cb(nil, _("搜索关键词为空"))
        return nil
    end
    count = tonumber(count) or DEFAULT_COUNT
    if count <= 0 then count = DEFAULT_COUNT end
    if count > 20 then count = 20 end

    local url = SEARCH_URL .. "?keyword=" .. socketurl.escape(query)
        .. "&maxIdx=0&count=" .. tostring(count)

    return Request.request({
        url = url,
        method = "GET",
        headers = {
            ["User-Agent"] = Request.randomUA(),
            ["Accept"] = "application/json, text/plain, */*",
            ["Accept-Language"] = "zh-CN,zh;q=0.9,en;q=0.8",
            ["Referer"] = "https://weread.qq.com/",
            ["Origin"] = "https://weread.qq.com",
        },
        timeout = 30,
    }, function(res, err)
        if err then
            logger.warn("weread search error:", err)
            cb(nil, err)
            return
        end
        local code = tonumber(res and res.code)
        if not code or code ~= 200 then
            cb(nil, _("网络请求失败"))
            return
        end
        local body = res.body or ""
        local ok, data = pcall(JSON.decode, body)
        if not ok or type(data) ~= "table" then
            cb(nil, _("响应格式错误"))
            return
        end
        if not data.books or type(data.books) ~= "table" then
            cb({})
            return
        end
        local results = {}
        for _, row in ipairs(data.books) do
            local info = row.bookInfo
            if type(info) == "table" and info.title and info.title ~= "" then
                if tonumber(info.soldout) ~= 1 then
                    local mapped = mapBook(info, row)
                    if mapped then
                        results[#results + 1] = mapped
                    end
                end
            end
        end
        cb(results)
    end)
end

--- 映射微信读书响应到统一格式
---@param info table
---@param row table
---@return table|nil
function mapBook(info, row)
    local title = trim(info.title)
    if title == "" then return nil end

    local rawRating = tonumber(info.newRating or row.newRating) or 0
    local rating10 = rawRating > 0 and (math.floor(rawRating / 10 + 0.5) / 10) or 0

    local intro = trim(info.intro)
    local category = trim(info.category)
    local tags = {}
    if category ~= "" then
        for p in category:gmatch("[^-／/|、,，]+") do
            local part = p:gsub("^%s+", ""):gsub("%s+$", "")
            if part ~= "" then tags[#tags + 1] = part end
        end
    end

    local detail = info.newRatingDetail or row.newRatingDetail
    if type(detail) == "table" and detail.title and detail.title ~= "" then
        local found = false
        for _, t in ipairs(tags) do
            if t == detail.title then found = true break end
        end
        if not found then tags[#tags + 1] = detail.title end
    end

    local publishTime = info.publishTime or ""
    local year = publishTime:match("(%d%d%d%d)")

    local bookId = info.bookId or ""
    local url = trim(info.deepLink)
    if url == "" and bookId ~= "" then
        url = "https://weread.qq.com/web/reader/" .. bookId
    end

    local price = tonumber(info.price)
    if price and price < 0 then price = nil end

    return {
        title = title,
        author = trim(info.author),
        publisher = trim(info.publisher),
        year = year or "",
        isbn = trim(info.isbn),
        rating = rating10 > 0 and tostring(rating10) or "",
        intro = intro,
        tags = tags,
        cover_url = trim(info.cover),
        url = url,
        series = trim(info.lPushName),
        price = price and tostring(price) or "",
        source = "weread",
        bookId = bookId,
    }
end

return Weread
