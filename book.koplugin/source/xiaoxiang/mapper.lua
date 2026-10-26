--[[--
潇湘书院数据映射（纯函数）：PC 搜索页 HTML、手机站目录 / 章节页 → 领域对象。

@module koplugin.book.source.xiaoxiang.mapper
--]]

local JSON = require("json")
local Text = require("utils.text")

local Mapper = {}

local SOURCE_ID = "xiaoxiang"

--- 搜索页 HTML → Book[]。
---@param html string
---@return Book[]
function Mapper.search(html)
    local out = {}
    for item in html:gmatch('<li style="padding%-bottom:15px;">(.-)</li>') do
        local id, title = item:match('<h4><a href="/book/(%d+)"[^>]*>([^<]*)</a>')
        if id then
            local sub = item:match('<span class="subtitle">(.-)</h4>') or ""
            local cover = item:match('<img src="([^"]*)"')
            out[#out + 1] = {
                source_id = SOURCE_ID,
                stable_id = id,
                title = Text.xmlDecode(title),
                authors = Text.trim(Text.xmlDecode(sub:match("</i>([^<]*)</a>") or "")),
                category = sub:match("</a><span>([^<]*)</span>"),
                intro = Text.trim(Text.xmlDecode(item:match('<p class="detail"[^>]*>(.-)</p>') or "")),
                cover = cover and (cover:gsub("^//", "https://")),
            }
        end
    end
    return out
end

--- 手机站榜单页 HTML → Book[]。每本是一个 `<a href="/book/ID">`，封面 alt 是书名，book-module 是「作者·状态·字数」。
---@param html string
---@return Book[]
function Mapper.rank(html)
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
    return out
end

--- 目录缓存格式版本。
Mapper.TOC_VERSION = 1

--- 手机站目录页 → 目录。页面内嵌 SSR JSON，`"chapters":[` 之后是扁平对象：type 0 是卷，type 1 是章（price > 0 为 VIP）。
---@param html string
---@return BookChapter[]
function Mapper.toc(html)
    local toc = {}
    local start = html:find('"chapters":[{"type":0', 1, true)
    if not start then return toc end
    for obj in html:sub(start + 12):gmatch("%b{}") do
        local ok, row = pcall(JSON.decode, obj)
        if not (ok and type(row) == "table" and row.type) then break end
        if row.type == 1 then
            toc[#toc + 1] = {
                idx = #toc + 1,
                uid = tostring(row.ccid),
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
    if (tonumber(chapter.chapterPrice) or 0) > 0 and chapter.auth ~= true then return nil, "unpaid" end
    if chapter.encrypt == true then return nil, "encrypted", chapter end
    local lines = {}
    for line in tostring(chapter.chapterContent or ""):gmatch("[^\r\n]+") do
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
