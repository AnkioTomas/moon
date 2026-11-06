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
    return (html:gsub("%s+", " "))
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
        local author = forward:match('class="authorNm"[^>]*>(.-)</div>')
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
    return html:find("pgNum=" .. next_page, 1, true) ~= nil
        or html:find("/tadu/space/my-bookshelf/" .. next_page, 1, true) ~= nil
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

--- 正文 JSON。夹带的塔读推广段丢掉。
---@param wire table|nil
---@return string|nil
---@return string|nil
function Mapper.content(wire)
    if type(wire) ~= "table" then return nil, "响应无效" end
    if tostring(wire.status or "") ~= "200" then
        local msg = type(wire.msg) == "string" and wire.msg ~= "" and wire.msg or "响应无效"
        return nil, msg
    end
    local data = wire.data
    local html = type(data) == "table" and data.content or nil
    if type(html) ~= "string" or html == "" then return nil, "响应无效" end
    html = html:gsub("<p[^>]*>[^<]*塔读[^<]*</p>", "")
    return html
end

return Mapper
