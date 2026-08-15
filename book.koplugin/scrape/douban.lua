--[[--
豆瓣图书搜索

爬取 douban.com/search HTML，正则提取关键字段
不做完整 DOM 解析，只提取核心信息

@module koplugin.book.scrape.douban
--]]

local Request = require("http.request")
local socketurl = require("socket.url")
local logger = require("logger")
local _ = require("gettext")

local Douban = {}

local SEARCH_URL = "https://www.douban.com/search"

--- 生成随机 User-Agent
---@return string
local function randomUA()
    local uas = {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    }
    return uas[math.random(#uas)]
end

--- 生成随机 IP（X-Forwarded-For）
---@return string
local function randomIP()
    return string.format("%d.%d.%d.%d",
        math.random(1, 223),
        math.random(0, 255),
        math.random(0, 255),
        math.random(1, 254)
    )
end

--- 计算字符串相似度（简化版 similar_text）
---@param s1 string
---@param s2 string
---@return number 0-1
local function similarity(s1, s2)
    s1 = s1:lower():gsub("%s+", "")
    s2 = s2:lower():gsub("%s+", "")
    if s1 == s2 then return 1.0 end
    if s1 == "" or s2 == "" then return 0.0 end

    local len1, len2 = #s1, #s2
    local maxLen = math.max(len1, len2)
    if maxLen == 0 then return 1.0 end

    local matches = 0
    local i, j = 1, 1
    while i <= len1 and j <= len2 do
        if s1:sub(i, i) == s2:sub(j, j) then
            matches = matches + 1
            i = i + 1
            j = j + 1
        else
            j = j + 1
        end
    end

    return matches / maxLen
end

--- 从 HTML 提取搜索结果列表
---@param html string
---@param query string
---@return table[]
local function parseSearchResults(html, query)
    local results = {}

    for block in html:gmatch('<div class="result".->.-</div>%s*</div>%s*</div>') do
        local title, url = block:match('<h3>.-<a%s+href="([^"]+)"[^>]*>([^<]+)</a>')
        if not title then
            url, title = block:match('<h3>.-<a%s+href="([^"]+)"[^>]*>%s*<span[^>]*>([^<]+)</span>')
        end

        if title and url then
            title = title:gsub("^%s+", ""):gsub("%s+$", "")
            local subject_id = url:match("subject/(%d+)")
            if subject_id then
                local sim = similarity(query, title)
                if sim >= 0.6 then
                    local cast = block:match('<div class="subject%-cast"[^>]*>([^<]+)</div>')
                    local author, publisher, year = "", "", ""
                    if cast then
                        local parts = {}
                        for p in cast:gmatch("[^/]+") do
                            local part = p:gsub("^%s+", ""):gsub("%s+$", "")
                            if part ~= "" then
                                parts[#parts + 1] = part
                            end
                        end
                        if #parts > 0 then author = parts[1] end
                        if #parts > 2 then publisher = parts[#parts - 1] end
                        for _, p in ipairs(parts) do
                            local y = p:match("^(%d%d%d%d)$")
                            if y then year = y break end
                        end
                    end

                    local cover = block:match('<img%s+[^>]*src="([^"]+)"')
                    local rating = block:match('<span class="rating_nums">([^<]+)</span>')
                    if rating then
                        rating = rating:gsub("^%s+", ""):gsub("%s+$", "")
                    end

                    local intro = block:match('<div class="content">%s*<p[^>]*>([^<]+)</p>')
                    if intro then
                        intro = intro:gsub("^%s+", ""):gsub("%s+$", "")
                    end

                    results[#results + 1] = {
                        title = title,
                        author = author,
                        publisher = publisher,
                        year = year,
                        cover_url = cover or "",
                        rating = rating or "",
                        intro = intro or "",
                        url = "https://book.douban.com/subject/" .. subject_id .. "/",
                        douban_id = subject_id,
                        similarity = sim,
                        source = "douban",
                    }
                end
            end
        end
    end

    table.sort(results, function(a, b)
        return a.similarity > b.similarity
    end)

    local top = {}
    for i = 1, math.min(10, #results) do
        top[#top + 1] = results[i]
    end

    return top
end

--- 搜索豆瓣图书
---@param query string
---@param cb fun(results: table[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Douban.searchAsync(query, cb)
    query = (query or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if query == "" then
        cb(nil, _("搜索关键词为空"))
        return nil
    end

    local url = SEARCH_URL .. "?cat=1001&q=" .. socketurl.escape(query)

    return Request.request({
        url = url,
        method = "GET",
        headers = {
            ["User-Agent"] = randomUA(),
            ["X-Forwarded-For"] = randomIP(),
            ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            ["Accept-Language"] = "zh-CN,zh;q=0.9,en;q=0.8",
            ["Accept-Encoding"] = "gzip, deflate, br",
            ["Connection"] = "keep-alive",
            ["Upgrade-Insecure-Requests"] = "1",
            ["Sec-Fetch-Dest"] = "document",
            ["Sec-Fetch-Mode"] = "navigate",
            ["Sec-Fetch-Site"] = "none",
            ["Sec-Fetch-User"] = "?1",
            ["Cache-Control"] = "max-age=0",
        },
        timeout = 30,
    }, function(res, err)
        if err then
            logger.warn("douban search error:", err)
            cb(nil, err)
            return
        end

        local code = tonumber(res and res.code)
        if not code or code ~= 200 then
            cb(nil, _("网络请求失败"))
            return
        end

        local html = res.body or ""
        if html == "" then
            cb(nil, _("响应为空"))
            return
        end

        local results = parseSearchResults(html, query)
        cb(results)
    end)
end

return Douban
