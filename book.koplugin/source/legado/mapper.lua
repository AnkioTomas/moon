--[[--
阅读（Legado）Web 服务数据映射（纯函数）。

@module koplugin.book.source.legado.mapper
--]]

local Text = require("utils.text")

local Mapper = {}

local SOURCE_ID = "legado"

--- 封面走阅读服务器的 /cover 代理（原地址常要 Referer / 本地路径）。
---@param coverUrl fun(path: string): string
---@param row table
---@return string|nil
local function cover(coverUrl, row)
    local path = row.customCoverUrl
    if type(path) ~= "string" or path == "" then path = row.coverUrl end
    if type(path) ~= "string" or path == "" then return nil end
    return coverUrl(path)
end

--- 书的 group 是分组 id 的位掩码（id 为 2 的幂）；返回命中的分组名，没有分组返回 nil。
local function groupNames(groups, mask)
    local names = {}
    mask = tonumber(mask) or 0
    for _idx, g in ipairs(groups) do
        local id = tonumber(g.groupId)
        if id and id > 0 and type(g.groupName) == "string" and math.floor(mask / id) % 2 == 1 then
            names[#names + 1] = g.groupName
        end
    end
    return #names > 0 and table.concat(names, ",") or nil
end

--- 书架行 → Book[]。rows.groups 有值时分类取阅读 App 的书架分组（权威：没分组就是未分类）；否则退回书源标签 kind。bookUrl 是书在阅读 App 里的唯一键。
---@param coverUrl fun(path: string): string 封面代理地址构造（Client.coverUrl）
---@param rows table[]
---@return Book[]
function Mapper.shelfList(coverUrl, rows)
    local out, groups = {}, rows.groups
    for _idx, row in ipairs(rows) do
        if type(row.bookUrl) == "string" and row.bookUrl ~= "" then
            out[#out + 1] = {
                source_id = SOURCE_ID,
                stable_id = row.bookUrl,
                title = row.name,
                authors = row.author,
                category = groups and groupNames(groups, row.group) or (not groups and row.kind or nil),
                category_authoritative = groups and true or nil,
                intro = row.intro and Text.stripHtml(row.intro),
                cover = cover(coverUrl, row),
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

--- 目录：按服务端顺序，idx 连续，uid 是 0 基章节序号；origin 是书源（轻阅读取正文要用，随目录落盘）。
---@param rows table[]
---@param origin string|nil
---@return BookChapter[]
function Mapper.toc(rows, origin)
    local toc = {}
    for i, row in ipairs(rows) do
        toc[i] = { idx = i, uid = tostring(tonumber(row.index) or (i - 1)), title = row.title, origin = origin }
    end
    return toc
end

--- 正文纯文本里夹着 ``<img>``（图片章、网站插图）：图片留成真标签，其余照旧转义，否则标签原样显示。
--- 懒加载占位用的 data:image/svg+xml 没有内容，直接丢掉；src 尾部 Legado 的 ``,{请求头 JSON}`` 剥掉。
---@param title string
---@param text string
---@param imageUrl fun(src: string): string 相对图片地址补全（Client.imageUrl）
---@param reviews boolean|nil 保存阅读 App 的段落编号
---@return string
function Mapper.chapterHtml(title, text, imageUrl, reviews)
    if reviews then
        local paragraph = 0
        text = (text:gsub("\n+", "\n") .. "\n"):gsub("(.-)\n", function(line)
            paragraph = paragraph + 1
            return line .. "\2" .. paragraph .. "\2\n"
        end)
    end
    local imgs = {}
    text = text:gsub("<img%s[^>]*>", function(tag)
        local src = tag:match('src%s*=%s*"([^"]*)"') or tag:match("src%s*=%s*'([^']*)'")
        src = src and src:gsub(",%s*{.*$", "")
        if not src or src == "" or src:find("^data:image/svg") then return "" end
        imgs[#imgs + 1] = '<img src="' .. Text.xmlEscape(imageUrl(Text.xmlDecode(src))) .. '"/>'
        return "\1" .. #imgs .. "\1"
    end)
    local html = Text.chapterHtml(title, text)
    if reviews then
        html = html:gsub("<p>(.-)\2(%d+)\2</p>", function(body, paragraph)
            body = Text.rtrim(body)
            if body == "" then return "" end
            return '<p id="moon-legado-paragraph-' .. paragraph .. '">' .. body .. "</p>"
        end)
    end
    return (html:gsub("\1(%d+)\1", function(n) return imgs[tonumber(n)] end))
end

--- reader3 本地 EPUB 资源 → 正文片段；图片按章节 URL 解析并规范化属性，供公共 Assets 落地。
---@param title string
---@param raw string
---@param base string
---@param imageUrl fun(src: string, base: string): string
---@return string|nil
function Mapper.assetHtml(title, raw, base, imageUrl)
    local inner = Text.htmlBodyFragment(raw)
        :gsub("<script[^>]*>.-</script>", "")
        :gsub("<style[^>]*>.-</style>", "")
    local function svgToImg(block)
        local href = block:match('xlink:href%s*=%s*"([^"]*)"')
            or block:match("xlink:href%s*=%s*'([^']*)'")
            or block:match('href%s*=%s*"([^"]*)"')
            or block:match("href%s*=%s*'([^']*)'")
        if not href or href == "" then return "" end
        return '<img src="' .. Text.xmlEscape(Text.xmlDecode(href)) .. '"/>'
    end
    inner = inner:gsub("<svg[^>]*>.-</svg>", svgToImg)
        :gsub("<image%s[^>]-/>", svgToImg)
    inner = inner:gsub("<img%s+[^>]*>", function(tag)
        return (tag:gsub("src%s*=%s*(['\"])(.-)%1", function(_quote, src)
            if src == "" then return 'src=""' end
            local url = Text.escapeUrl(imageUrl(Text.xmlDecode(src), base))
            return 'src="' .. Text.xmlEscape(url) .. '"'
        end, 1))
    end)
    if not inner:find("<img", 1, true) and Text.stripHtml(inner) == "" then return nil end
    return "<h1>" .. Text.xmlEscape(title) .. "</h1>\n" .. inner
end

return Mapper
