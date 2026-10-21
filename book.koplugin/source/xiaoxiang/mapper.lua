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

--- 章节页 → 正文纯文本；没买的 VIP 章页面只有预览（正文容器带 lock-mask）返回 nil, "unpaid"。
---@param html string
---@return string|nil text
---@return "unpaid"|nil kind
function Mapper.content(html)
    local attrs, body = html:match('<main id="content"([^>]*)>(.-)</main>')
    if not body then return nil end
    if attrs:find("lock-mask", 1, true) then return nil, "unpaid" end
    local lines = {}
    for paragraph in body:gmatch("<p>(.-)</p>") do
        local line = Text.trim(Text.xmlDecode((paragraph:gsub("<[^>]*>", ""))))
        if line ~= "" then lines[#lines + 1] = line end
    end
    if #lines == 0 then return nil end
    return table.concat(lines, "\n")
end

return Mapper
