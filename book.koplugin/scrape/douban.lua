--[[--
豆瓣图书搜索

爬取 douban.com/search HTML，正则提取关键字段
不做完整 DOM 解析，只提取核心信息

@module koplugin.book.scrape.douban
--]]

local Request = require("http.request")
local logger = require("utils.log")
local Text = require("utils.text")
local _ = require("gettext")

local Douban = {}

local trim = Text.trim

local SEARCH_URL = "https://www.douban.com/search"

--- 豆瓣图片 CDN 防盗链：不带 Referer 一律 418，带上才给图。
--- 跟着结果走，显示封面和刮削落盘用同一份头。
local COVER_HEADERS = {
    ["Referer"] = "https://book.douban.com/",
}

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

--- 从链接 / onclick 里抠豆瓣 subject id。
--- 现在搜索结果 href 是 link2 跳转，subject 被编成 subject%2F123。
---@param block string
---@param url string|nil
---@return string|nil
local function extractSubjectId(block, url)
    if type(url) == "string" then
        local decoded = Text.urlDecode(Text.xmlDecode(url))
        local id = decoded and decoded:match("subject/(%d+)")
        if id then
            return id
        end
    end
    return block:match("sid:%s*(%d+)")
end

--- 解析 subject-cast：作者 / [译者 /] 出版社 / 年份或日期 / [价格]
---@param cast string|nil
---@return string, string, string
local function parseCast(cast)
    local author, publisher, year = "", "", ""
    if not cast then
        return author, publisher, year
    end
    local parts = {}
    for p in cast:gmatch("[^/]+") do
        local part = trim(p)
        if part ~= "" then
            parts[#parts + 1] = part
        end
    end
    if #parts > 0 then author = parts[1] end
    -- 真实格式年份段可能是日期（2012-8-1）：认前 4 位数字；出版社取年份前一段
    local year_idx
    for i = 1, #parts do
        local y = parts[i]:match("^(%d%d%d%d)$") or parts[i]:match("^(%d%d%d%d)%-")
        if y then
            year = y
            year_idx = i
            break
        end
    end
    if year_idx and year_idx > 2 then
        publisher = parts[year_idx - 1]
    elseif not year_idx and #parts > 2 then
        publisher = parts[#parts - 1]
    end
    return author, publisher, year
end

--- 解析单个结果块；不匹配返回 nil。
---@param block string
---@param query string
---@return table|nil, string|nil reason
local function parseBlock(block, query)
    local url, title = block:match('<h3>.-<a%s+href="([^"]+)"[^>]*>([^<]+)</a>')
    if not title then
        url, title = block:match('<h3>.-<a%s+href="([^"]+)"[^>]*>%s*<span[^>]*>([^<]+)</span>')
    end
    if not title then
        return nil, "no_title"
    end

    title = trim(Text.xmlDecode(title))
    local subject_id = extractSubjectId(block, url)
    if not subject_id then
        return nil, "no_id"
    end

    local sim = similarity(query, title)
    if sim < 0.6 then
        return nil, "low_sim"
    end

    local cast = Text.xmlDecode(block:match('class="subject%-cast"[^>]*>([^<]+)<'))
    local author, publisher, year = parseCast(cast)

    local cover = block:match('<img%s+[^>]*src="([^"]+)"')
    if cover then cover = Text.xmlDecode(cover) end
    local rating = block:match('<span class="rating_nums">([^<]+)</span>')
    if rating then
        rating = trim(Text.xmlDecode(rating))
    end

    local intro = block:match("<p>([^<]+)</p>")
    if intro then
        intro = trim(Text.xmlDecode(intro))
    end

    return {
        title = title,
        author = author,
        publisher = publisher,
        year = year,
        cover_url = cover or "",
        cover_headers = COVER_HEADERS,
        rating = rating or "",
        intro = intro or "",
        url = "https://book.douban.com/subject/" .. subject_id .. "/",
        douban_id = subject_id,
        similarity = sim,
        source = "douban",
    }
end

--- 从 HTML 提取搜索结果列表
---@param html string
---@param query string
---@return table[]
local function parseSearchResults(html, query)
    local results = {}
    local skipped_id = 0
    local skipped_sim = 0
    local skipped_title = 0

    -- 按起始位置切片，避开脆弱的多层 </div> 闭合
    local starts = {}
    local pos = 1
    while true do
        local s = html:find('<div class="result">', pos, true)
        if not s then
            break
        end
        starts[#starts + 1] = s
        pos = s + 1
    end

    for i = 1, #starts do
        local from = starts[i]
        local to = (starts[i + 1] or (#html + 1)) - 1
        local item, reason = parseBlock(html:sub(from, to), query)
        if item then
            results[#results + 1] = item
        elseif reason == "no_id" then
            skipped_id = skipped_id + 1
        elseif reason == "low_sim" then
            skipped_sim = skipped_sim + 1
        else
            skipped_title = skipped_title + 1
        end
    end

    logger.info("douban parse:",
        "blocks=", #starts,
        "kept=", #results,
        "no_id=", skipped_id,
        "low_sim=", skipped_sim,
        "no_title=", skipped_title)

    table.sort(results, function(a, b)
        return a.similarity > b.similarity
    end)

    for i = #results, 11, -1 do results[i] = nil end
    return results
end

--- 搜索豆瓣图书
---@param query string
---@param cb fun(results: table[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Douban.searchAsync(query, cb)
    query = trim(query)
    if query == "" then
        cb(nil, _("搜索关键词为空"))
        return nil
    end

    local url = SEARCH_URL .. "?cat=1001&q=" .. Text.urlEncode(query)
    logger.info("douban search:", query, url)

    return Request.request({
        url = url,
        method = "GET",
        headers = {
            ["User-Agent"] = Request.randomUA(),
            ["X-Forwarded-For"] = Request.randomIP(),
            ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            ["Accept-Language"] = "zh-CN,zh;q=0.9,en;q=0.8",
            -- 不主动要 gzip：Turbo 不解压时 body 是二进制，解析直接变空
            ["Connection"] = "keep-alive",
            ["Upgrade-Insecure-Requests"] = "1",
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
        local html = res and res.body or ""
        local encoding = Request.header(res, "Content-Encoding")
        logger.info("douban response:",
            "code=", code,
            "bytes=", #html,
            "encoding=", encoding,
            "html=", html:find("<html", 1, true) ~= nil,
            "result_marker=", html:find('class="result"', 1, true) ~= nil)

        if not code or code ~= 200 then
            logger.warn("douban http not 200:", code)
            cb(nil, _("网络请求失败") .. " (" .. tostring(code) .. ")")
            return
        end

        if html == "" then
            cb(nil, _("响应为空"))
            return
        end

        -- 被风控 / 验证码页时，结果块为零
        if html:find("captcha", 1, true) or html:find("验证码", 1, true) then
            logger.warn("douban captcha page")
        end

        local results = parseSearchResults(html, query)
        if #results > 0 then
            logger.info("douban ok:", results[1].title, "sim=", results[1].similarity)
        else
            logger.warn("douban empty after parse; head=", html:sub(1, 200):gsub("%s+", " "))
        end
        cb(results)
    end)
end

return Douban
