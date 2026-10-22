--[[--
阅读（Legado）Web 服务数据映射（纯函数）。

@module koplugin.book.source.legado.mapper
--]]

local Text = require("utils.text")

local Mapper = {}

local SOURCE_ID = "legado"

--- 封面走阅读服务器的 /cover 代理（原地址常要 Referer / 本地路径）。
---@param base string
---@param row table
---@return string|nil
local function cover(base, row)
    local path = row.customCoverUrl
    if type(path) ~= "string" or path == "" then path = row.coverUrl end
    if type(path) ~= "string" or path == "" then return nil end
    return base .. "/cover?path=" .. Text.urlEncode(path)
end

--- 书架行 → Book[]。bookUrl 是书在阅读 App 里的唯一键。
---@param base string 服务器地址
---@param rows table[]
---@return Book[]
function Mapper.shelfList(base, rows)
    local out = {}
    for _idx, row in ipairs(rows) do
        if type(row.bookUrl) == "string" and row.bookUrl ~= "" then
            out[#out + 1] = {
                source_id = SOURCE_ID,
                stable_id = row.bookUrl,
                title = row.name,
                authors = row.author,
                category = row.kind,
                intro = row.intro and Text.stripHtml(row.intro),
                cover = cover(base, row),
            }
        end
    end
    return out
end

--- 书架行里的阅读位置（序号 0 基）。没读过返回 nil。
---@param row table|nil
---@return { index: integer, title: string|nil, offset: integer }|nil
function Mapper.readPos(row)
    local index = row and tonumber(row.durChapterIndex)
    if not index or (index == 0 and (tonumber(row.durChapterTime) or 0) <= 0) then return nil end
    local title = row.durChapterTitle
    return { index = index, title = type(title) == "string" and title ~= "" and title or nil,
        offset = tonumber(row.durChapterPos) or 0 }
end

--- 目录：按服务端顺序，idx 连续，uid 是 0 基章节序号。
---@param rows table[]
---@return BookChapter[]
function Mapper.toc(rows)
    local toc = {}
    for i, row in ipairs(rows) do
        toc[i] = { idx = i, uid = tostring(tonumber(row.index) or (i - 1)), title = row.title }
    end
    return toc
end

--- 正文纯文本里夹着 ``<img>``（图片章、网站插图）：图片留成真标签，其余照旧转义，否则标签原样显示。
--- 懒加载占位用的 data:image/svg+xml 没有内容，直接丢掉；src 尾部 Legado 的 ``,{请求头 JSON}`` 剥掉。
---@param title string
---@param text string
---@return string
function Mapper.chapterHtml(title, text)
    local imgs = {}
    text = text:gsub("<img%s[^>]*>", function(tag)
        local src = tag:match('src%s*=%s*"([^"]*)"') or tag:match("src%s*=%s*'([^']*)'")
        src = src and src:gsub(",%s*{.*$", "")
        if not src or src == "" or src:find("^data:image/svg") then return "" end
        imgs[#imgs + 1] = '<img src="' .. Text.xmlEscape(Text.xmlDecode(src)) .. '"/>'
        return "\1" .. #imgs .. "\1"
    end)
    return (Text.chapterHtml(title, text):gsub("\1(%d+)\1", function(n) return imgs[tonumber(n)] end))
end

return Mapper
