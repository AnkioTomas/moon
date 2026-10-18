--[[--
iRead 数据映射（纯函数）。

书的身份是书名：服务端按（用户, 书名）唯一，换书源时 bookUrl / sourceId 会变而书名不变。

@module koplugin.book.source.iread.mapper
--]]

local JSON = require("json")
local Text = require("utils.text")

local Mapper = {}

local SOURCE_ID = "iread"

---@param row table
---@return string|nil
local function cover(row)
    local url = row.customCoverUrl
    if type(url) ~= "string" or url == "" then url = row.coverUrl end
    if type(url) ~= "string" or url == "" then return nil end
    if url:sub(1, 2) == "//" then url = "https:" .. url end
    return url
end

--- 书架行 → Book[]。
---@param rows table[]
---@return Book[]
function Mapper.shelfList(rows)
    local out = {}
    for _idx, row in ipairs(rows) do
        if type(row.name) == "string" and row.name ~= "" then
            out[#out + 1] = {
                source_id = SOURCE_ID,
                stable_id = row.name,
                title = row.name,
                authors = row.author,
                category = row.kind,
                intro = row.intro and Text.stripHtml(row.intro),
                cover = cover(row),
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
    if not index then return nil end
    local offset = tonumber(row.durChapterPos) or 0
    if index == 0 and offset == 0 and (tonumber(row.durChapterTime) or 0) <= 0 then return nil end
    local title = row.durChapterTitle
    return { index = index, title = type(title) == "string" and title ~= "" and title or nil, offset = offset }
end

--- 目录：按服务端顺序，uid 是 0 基章序号；raw 是章节对象原样 JSON（开章接口要整个带回）。
---@param rows table[]
---@return BookChapter[]
function Mapper.toc(rows)
    local toc = {}
    for i, row in ipairs(rows) do
        toc[i] = { idx = i, uid = tostring(i - 1), title = row.title, raw = JSON.encode(row) }
    end
    return toc
end

--- 正文：服务端给纯文本；规则偶尔带 HTML 标签，剥掉免得标签原样显示。
---@param content string
---@return string
function Mapper.text(content)
    if content:find("<%s*/?%a[^>]*>") then return Text.stripHtml(content) end
    return content
end

return Mapper
