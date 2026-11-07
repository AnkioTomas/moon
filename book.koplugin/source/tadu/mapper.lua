--[[--
塔读网页 → 领域对象。纯函数，不发请求。

@module source.tadu.mapper
--]]

local Text = require("utils.text")

local Mapper = {}

local SOURCE_ID = "tadu"

--- 目录缓存格式。首章携带，变了就当缓存失效。
Mapper.TOC_VERSION = 1

---@param html string|nil
---@return string
local function flat(html)
    if type(html) ~= "string" then return "" end
    return (html:gsub("<!%-%-.-%-%->", ""):gsub("%s+", " "))
end

---@param value string|nil
---@return string
local function clean(value)
    if type(value) ~= "string" then return "" end
    return Text.trim(Text.xmlDecode(value:gsub("<[^>]+>", "")))
end

---@param id string|number
---@param title string|nil
---@param author string|nil
---@param intro string|nil
---@param cover string|nil
---@return Book
local function book(id, title, author, intro, cover)
    local picture = type(cover) == "string" and cover ~= "" and not cover:find("coverBg", 1, true)
        and Text.xmlDecode(cover) or nil
    local name = clean(author):gsub("%s*著%s*$", "")
    return {
        source_id = SOURCE_ID,
        stable_id = tostring(id),
        title = clean(title),
        authors = name,
        intro = clean(intro),
        cover = picture,
    }
end

--- 微信 qrconnect 页面里的 uuid。二维码内容是 confirm 链接。
---@param html string|nil
---@return string|nil
function Mapper.qrUuid(html)
    if type(html) ~= "string" then return nil end
    return html:match("/connect/qrcode/([%w_%-]+)")
end

---@param uuid string
---@return string
function Mapper.qrText(uuid)
    return "https://open.weixin.qq.com/connect/confirm?uuid=" .. Text.urlEncode(uuid)
end

--- 长轮询回包。405 确认，404 已扫码，408 继续等，403 拒绝，402 过期。
--- JSON（f=json）和页面里的 `wx_errcode=` 脚本都认。
---@param body string|nil
---@return "ok"|"wait"|"fail"|"expired"
---@return string|nil wx_code
---@return integer|nil errcode
function Mapper.wxStatus(body)
    if type(body) ~= "string" or body == "" then return "expired" end
    local code, wx_code
    if body:sub(1, 1) == "{" then
        local ok, wire = pcall(require("json").decode, body)
        if ok and type(wire) == "table" then
            code = tonumber(wire.wx_errcode)
            wx_code = wire.wx_code
        end
    end
    if not code then
        code = tonumber(body:match("wx_errcode%s*=%s*(%-?%d+)"))
        wx_code = body:match("wx_code%s*=%s*'([^']*)'") or body:match('wx_code%s*=%s*"([^"]*)"')
    end
    if code == 405 and type(wx_code) == "string" and wx_code ~= "" then return "ok", wx_code, code end
    if code == 404 or code == 408 then return "wait", nil, code end
    if code == 403 then return "fail", nil, code end
    return "expired", nil, code
end

--- 登录后的 /user/info。没有 user 就是还没登录。
---@param wire table|nil
---@return { name: string }|nil
function Mapper.user(wire)
    local user = type(wire) == "table" and type(wire.data) == "table" and wire.data.user or nil
    if type(user) ~= "table" then return nil end
    local name = type(user.nickname) == "string" and user.nickname ~= "" and user.nickname or user.username
    if type(name) ~= "string" or name == "" then return nil end
    return { name = name }
end

--- 搜索页和书库页共用的书卡。`bookNm` 里的高亮 span 去掉。
---@param html string|nil
---@return Book[]
function Mapper.books(html)
    local text = flat(html)
    local out, seen = {}, {}
    local pos = 1
    while true do
        local start, stop = text:find('class="bookNm"', pos, true)
        if not start then break end
        local back = text:sub(math.max(1, start - 800), start)
        local id = back:match(".*/book/(%d+)/")
        local inner = text:sub(stop + 1):match("^[^>]*>(.-)</a>")
        local forward = text:sub(stop, math.min(#text, stop + 500))
        local next_card = forward:find('class="bookNm"', 2, true)
        if next_card then forward = forward:sub(1, next_card - 1) end
        local author = forward:match('class="authorNm"[^>]*>(.-)</a>')
            or forward:match('class="authorNm"[^>]*>(.-)</div>')
        local intro = forward:match('class="bookIntro"[^>]*>(.-)</a>')
        local cover
        for found in back:gmatch('data%-src="([^"]+)"') do cover = found end
        if id and not seen[id] and clean(inner) ~= "" then
            seen[id] = true
            out[#out + 1] = book(id, inner, author, intro, cover)
        end
        pos = stop + 1
    end
    return out
end

--- 个人中心书架。空架是 `bookrack_table_kong`，有书时行上带 `data-bookid`。
--- 旧书架页的 `bookNm` 卡片也认。
---@param html string|nil
---@return Book[]
function Mapper.shelf(html)
    local text = flat(html)
    if text:find("bookrack_table_kong", 1, true) and not text:find("data-bookid", 1, true) then
        return {}
    end
    local out, seen = {}, {}
    local pos = 1
    while true do
        local _start, stop, id = text:find('data%-bookid%s*=%s*["\'](%d+)["\']', pos)
        if not _start then break end
        local window = text:sub(stop, math.min(#text, stop + 1200))
        local title = window:match('class="linkBlock"[^>]*>([^<]+)')
        local author = window:match('class="table_author".-<p[^>]*>([^<]*)')
        if not seen[id] and clean(title) ~= "" then
            seen[id] = true
            out[#out + 1] = book(id, title, author)
        end
        pos = stop + 1
    end
    if out[1] then return out end
    return Mapper.books(text)
end

--- 书架页。未登录时服务端直接回首页，不能当成空书架。
---@param html string|nil
---@return Book[]|nil
---@return string|nil
function Mapper.shelfPage(html)
    local text = flat(html)
    local title = text:match("<title>(.-)</title>") or ""
    if title:find("免费阅读最新热门小说", 1, true) then return nil, "未登录塔读" end
    if title:find("出错了", 1, true) then return nil, "塔读书架页面无法识别" end
    local books = Mapper.shelf(text)
    if #books > 0 then return books end
    if text:find("bookrack_table_kong", 1, true)
        or text:find("还没有", 1, true) or text:find("暂无", 1, true) then
        return {}
    end
    return nil, "塔读书架页面无法识别"
end

---@param html string|nil
---@param page integer
---@return boolean
function Mapper.shelfHasNext(html, page)
    if type(html) ~= "string" then return false end
    local next_page = tostring(page + 1)
    return html:find("pgNum=" .. next_page .. "%D") ~= nil
        or html:find("/tadu/space/my%-bookshelf/" .. next_page .. "%D") ~= nil
end

--- 只接受官网书库的九段节点，禁止把节点当任意路径。
function Mapper.storeNode(node)
    return type(node) == "string"
        and node:match("^%d+%-[atfsq]%-[0-9]+%-[0-9]+%-[atf]%-[0-9]+%-[pt]%-[0-9]+%-[0-9]+$") ~= nil
end

function Mapper.storePage(node, page)
    return (node:gsub("%-([pt])%-%d+%-(%d+)$", "-%1-" .. page .. "-%2"))
end

--- 从实际可见链接取筛选；注释里的出版、资费入口不是可用能力。
function Mapper.storeGroups(html)
    local text, groups = flat(html), {}
    for block in text:gmatch('<div class="lkLine[^"]*"[^>]*>(.-)</div>') do
        local title = clean(block:match("<span[^>]*>(.-)</span>"))
        local chips, active = {}, nil
        for attrs, name in block:gmatch("<a([^>]+)>(.-)</a>") do
            local node = attrs:match('href="/store/([^"]+)"')
            if Mapper.storeNode(node) then
                chips[#chips + 1] = { id = node, title = clean(name) }
                if attrs:find("current", 1, true) then active = node end
            end
        end
        if #chips > 1 then groups[#groups + 1] = { title = title, chips = chips, active = active } end
    end
    local sort = text:match('<div class="tabList">(.-)<div class="rtIcon">')
    if sort then
        local chips, active = {}, nil
        for attrs, name in sort:gmatch("<span([^>]+)>(.-)</span>") do
            local node = attrs:match("/store/([%w%-]+)")
            if Mapper.storeNode(node) then
                chips[#chips + 1] = { id = node, title = clean(name) }
                active = node
            end
        end
        for attrs, name in sort:gmatch("<a([^>]+)>(.-)</a>") do
            local node = attrs:match('href="/store/([^"]+)"')
            if Mapper.storeNode(node) then
                chips[#chips + 1] = { id = node, title = clean(name) }
                if attrs:find("current", 1, true) then active = node end
            end
        end
        if #chips > 1 then groups[#groups + 1] = { title = "排序", chips = chips, active = active } end
    end
    return groups
end

function Mapper.storeMore(html, node, page)
    return flat(html):find('href="/store/' .. Mapper.storePage(node, page + 1) .. '"', 1, true) ~= nil
end

--- 列表页必须有结果容器，错误页不是空结果。
function Mapper.listPage(html)
    local text = flat(html)
    local books = Mapper.books(text)
    if #books > 0 or text:find('class="bookList', 1, true)
        or text:find("没有找到", 1, true) then return books end
    return nil, "响应无效"
end

--- 作品评论区绑定 bookId，不是章评。这里只读已核对的网页列表。
function Mapper.reviews(html)
    local text, items = flat(html), {}
    local _text, expected = text:gsub('<div class="commentIntro">', "")
    for block, date in text:gmatch('<div class="commentIntro">(.-)<span class="time"[^>]*>(.-)</span>') do
        local body = clean(block:match("<p[^>]*>(.-)</p>"))
        local title = clean(block:match("<h5[^>]*>(.-)</h5>"))
        if body ~= "" or title ~= "" then
            items[#items + 1] = {
                author = clean(block:match("<h4[^>]*>(.-)</h4>")),
                text = title ~= "" and title .. "\n" .. body or body,
                time = clean(date),
            }
        end
    end
    if #items ~= expected then return nil end
    if #items == 0 and not text:find("作品评论区", 1, true)
        and not text:find("暂无评论", 1, true) then return nil end
    local pages = 1
    for page in text:gmatch("/v4/book/comment/%d+/%d+/(%d+)") do pages = math.max(pages, tonumber(page)) end
    return items, pages
end

--- 书籍页。
---@param html string|nil
---@param id string
---@return Book|nil
function Mapper.detail(html, id)
    local text = flat(html)
    local title = text:match('class="bkNm"[^>]*data%-name="([^"]+)"')
        or text:match('class="bkNm"[^>]*>([^<]+)')
    if not title or clean(title) == "" then return nil end
    local author = text:match('class="author"[^>]*>([^<]+)')
    local intro = text:match('class="intro"[^>]*>(.-)</p>')
    local cover = text:match('class="bookImg"[^>]*>.-data%-src="([^"]+)"')
    return book(id, title, author, intro, cover)
end

--- 阅读页目录。链接顺序就是正文接口的分卷序号。
---@param html string|nil
---@return BookChapter[]
function Mapper.chapters(html)
    local text = flat(html)
    local toc, seen = {}, {}
    for id, title in text:gmatch('href="%s*/book/%d+/(%d+)/%s*"[^>]*>([^<]+)') do
        if not seen[id] and clean(title) ~= "" then
            seen[id] = true
            local idx = #toc + 1
            toc[idx] = {
                idx = idx,
                uid = id,
                source_idx = tostring(idx),
                title = clean(title),
                depth = 1,
            }
        end
    end
    if toc[1] then toc[1].toc_version = Mapper.TOC_VERSION end
    return toc
end

--- 扫码限制只在阅读页声明；正文接口仍会返回 status=200 的预览。
---@param html string
---@param stable_id string
---@return table|nil
function Mapper.reading(html, stable_id)
    local text, resource, gated = flat(html), nil, false
    for tag in text:gmatch("<[^>]+>") do
        if tag:match('id="bookPartResourceUrl"') then
            resource = tag:match('value="([^"]+)"')
        end
        local classes = tag:match('class="([^"]+)"')
        if classes and (" " .. classes .. " "):find(" appQrCode ", 1, true) then
            if tag:match('data%-url="([^"]+)"') ~= "/qrcode/invoke"
                or tag:match('data%-status="([^"]+)"') ~= "/qrcode/check" then return nil end
            gated = true
        end
    end
    local id, part
    if resource then id, part = resource:match("^/getPartContentByCodeTable/(%d+)/(%d+)$") end
    if id ~= stable_id or not part then return nil end
    return { resource = resource, gated = gated }
end

--- 正文 JSON。夹带的塔读推广段丢掉。
---@param wire table|nil
---@return string|nil
---@return string|nil
---@return {url: string, html: string}|nil
function Mapper.content(wire, chapter_uid)
    if type(wire) ~= "table" then return nil, "响应无效" end
    if tostring(wire.status or "") ~= "200" then
        local msg = type(wire.msg) == "string" and wire.msg ~= "" and wire.msg or "响应无效"
        return nil, msg
    end
    local data = wire.data
    local html = type(data) == "table" and data.content or nil
    if type(html) ~= "string" or html == "" then return nil, "响应无效" end
    if chapter_uid then
        local hidden = Text.base64Encode(tostring(chapter_uid))
        html = html:gsub('<p([^>]*)>(.-)</p>', function(attrs, body)
            if attrs:match('data%-limit="([^"]+)"') == hidden then return "" end
            return "<p" .. attrs .. ">" .. body .. "</p>"
        end)
    end
    if type(data.url) == "string" and data.url ~= "" then
        return nil, "塔读章节字体还原失败，请重试", { url = data.url, html = html }
    end
    return html
end

return Mapper
