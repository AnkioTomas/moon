--[[--
潇湘书院数据映射（纯函数）：新站 JSON、官网 SSR 与旧榜单 HTML → 领域对象。

@module koplugin.book.source.xiaoxiang.mapper
--]]

local JSON = require("json")
local Text = require("utils.text")
local _ = require("gettext")

local Mapper = {}

local SOURCE_ID = "xiaoxiang"

--- 新站 JSON 的整数身份不能经过 Lua number；不匹配小数、指数或字符串里的转义引号。
function Mapper.decode(raw)
    local encoded = raw:gsub('("[%w_]+"%s*:%s*)(%d+)([,}%]%s])', function(key, value, tail)
        return key .. (#value >= 16 and ('"' .. value .. '"') or value) .. tail
    end)
    local ok, data = pcall(JSON.decode, encoded)
    if not ok or type(data) ~= "table" then return nil, _("响应无效") end
    return data
end

--- 电脑与移动官网共用的 SSR 容器，只取公开页面数据。
function Mapper.state(html)
    local raw = html:match('<script[^>]-id="vite%-plugin%-ssr_pageContext"[^>]*>(.-)</script>')
    if not raw then return nil, _("响应无效") end
    local data = Mapper.decode(raw)
    local context = data and data.pageContext
    local props = type(context) == "table" and context.pageProps
    local page_data = type(props) == "table" and props.pageData
    if type(page_data) ~= "table" then return nil, _("响应无效") end
    return page_data
end

--- 分类库、搜索与详情的公开字段有两套命名，身份始终保留字符串。
function Mapper.books(rows)
    if type(rows) ~= "table" then return nil, _("响应无效") end
    local books = {}
    for _idx, row in ipairs(rows) do
        if type(row) ~= "table" then return nil, _("响应无效") end
        local id, title = row.cbId or row.cbid, row.bookName or row.title
        if type(id) ~= "string" or not id:match("^%d+$") or type(title) ~= "string" then
            return nil, _("响应无效")
        end
        books[#books + 1] = {
            source_id = SOURCE_ID, stable_id = id, title = Text.trim(title),
            authors = Text.trim(row.authorName or row.author or ""),
            category = row.cate2Name or row.catel2name or row.categoryShortName,
            intro = Text.trim(row.intro or ""), words = tonumber(row.totalWords),
            cover = "https://bookcover.yuewen.com/qdbimg/349573/c_" .. id .. "/180",
        }
    end
    return books
end

function Mapper.detail(html)
    local data, err = Mapper.state(html)
    if not data then return nil, err end
    local detail = data.detailData or data.bookInfo or data
    local books, reason = Mapper.books({ detail })
    return books and books[1], reason
end

--- 手机站榜单 SSR 中按栏目名选当前榜单；兼容旧 HTML。
---@param html string
---@param title string|nil
---@return Book[]|nil
---@return string|nil
function Mapper.rank(html, title)
    if title and html:find('id="vite-plugin-ssr_pageContext"', 1, true) then
        local data, err = Mapper.state(html)
        if not data then return nil, err end
        for _idx, section in ipairs(data) do
            if type(section) ~= "table" then return nil, _("响应无效") end
            local info = section.columnInfo
            if type(info) == "table" and info.name == title then return Mapper.books(section.bookList) end
        end
        return nil, _("响应无效")
    end
    local out = {}
    for id, item in html:gmatch('<a href="/book/(%d+)"[^>]*data%-bookid=.-(<div class="common%-img".-)</a>') do
        local title = item:match('class="book%-title"[^>]*>([^<]*)<')
        if title then
            local module = item:match('class="book%-module"[^>]*>(.-)</p>') or ""
            local cover = item:match('<img src="([^"]*)"')
            out[#out + 1] = {
                source_id = SOURCE_ID,
                stable_id = id,
                title = Text.xmlDecode(title),
                authors = Text.trim(Text.xmlDecode(module:match("^([^<]*)") or "")),
                intro = Text.trim(Text.xmlDecode(item:match('class="book%-profile"[^>]*>([^<]*)<') or "")),
                cover = cover and (cover:gsub("^//", "https://")),
            }
        end
    end
    if #out == 0 then return nil, _("响应无效") end
    return out
end

--- 目录缓存格式版本。
Mapper.TOC_VERSION = 1

--- 手机站目录页 → 目录。页面内嵌 SSR JSON，`"chapters":[` 之后是扁平对象：type 0 是卷，type 1 是章（price > 0 为 VIP）。
---@param html string
---@return BookChapter[]|nil
---@return string|nil
function Mapper.toc(html)
    local toc = {}
    local rows
    if html:find('id="vite-plugin-ssr_pageContext"', 1, true) then
        local data, err = Mapper.state(html)
        if not data then return nil, err end
        rows = data.chapters or data.chapterListData
    else
        local raw = html:match('"chapters":%s*(%b[])')
        rows = raw and Mapper.decode('{"rows":' .. raw .. "}")
        rows = rows and rows.rows
    end
    if type(rows) ~= "table" then return nil, _("响应无效") end
    for _idx, row in ipairs(rows) do
        if type(row) ~= "table" or (row.type ~= 0 and row.type ~= 1) then return nil, _("响应无效") end
        if row.type == 1 then
            if type(row.ccid) ~= "string" or not row.ccid:match("^%d+$") or type(row.title) ~= "string" then
                return nil, _("响应无效")
            end
            toc[#toc + 1] = {
                idx = #toc + 1,
                uid = row.ccid,
                title = row.title,
                vip = (tonumber(row.price) or 0) > 0 or nil,
            }
        end
    end
    if toc[1] then toc[1].toc_version = Mapper.TOC_VERSION end
    return toc
end

--- 章节接口回包 → 正文纯文本。没买的 VIP 章（价格 > 0 且 auth 不为真）只有 130 字预览，返回 nil, "unpaid"。
--- 正文段落以 \r\n 分隔、每段前有全角缩进。
---@param wire table
---@return string|nil text
---@return "unpaid"|"encrypted"|nil kind
---@return table|nil encrypted
function Mapper.content(wire)
    local chapters = type(wire.data) == "table" and wire.data.chapterContents
    local chapter = chapters and chapters[1]
    if type(chapter) ~= "table" then return nil end
    local price = tonumber(chapter.chapterPrice)
    if not price then return nil end
    if price > 0 and chapter.auth ~= true then return nil, "unpaid" end
    if chapter.encrypt == true then return nil, "encrypted", chapter end
    if type(chapter.chapterContent) ~= "string" then return nil end
    local lines = {}
    for line in chapter.chapterContent:gmatch("[^\r\n]+") do
        line = Text.trim(line)
        while line:sub(1, 3) == "\227\128\128" do line = Text.trim(line:sub(4)) end
        if line ~= "" then lines[#lines + 1] = line end
    end
    if #lines == 0 then return nil end
    return table.concat(lines, "\n")
end

--- 书架行 → Book[]。封面按书 id 拼（书架接口不给）。
---@param rows table[]
---@return Book[]
function Mapper.shelfList(rows)
    local out = {}
    for _idx, row in ipairs(rows) do
        local id = tostring(row.bookid)
        out[#out + 1] = {
            source_id = SOURCE_ID,
            stable_id = id,
            title = Text.trim(row.title or ""),
            authors = Text.trim(row.author or ""),
            cover = "https://bookcover.yuewen.com/qdbimg/349573/c_" .. id .. "/180",
        }
    end
    return out
end

--- 书架行 → 书 id → 最近读到的章 id（ccid 为 "0" 表示没读过）。
---@param rows table[]
---@return table<string, string>
function Mapper.progress(rows)
    local out = {}
    for _idx, row in ipairs(rows) do
        local ccid = tostring(row.ccid or "0")
        if ccid ~= "0" then out[tostring(row.bookid)] = ccid end
    end
    return out
end

return Mapper
