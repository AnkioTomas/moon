--[[--
拷贝漫画 App 章节载荷。

chapter2 返回 ``contents``（图片 URL）和 ``words``（阅读序号）。
低清 ``.c800x.`` 换成 ``.c1500x.``，与 kComics 一致。

@module koplugin.book.source.copymanga.protocol
--]]

local Protocol = {}

---@param wire table|nil
---@return table|nil
local function chapterRoot(wire)
    if type(wire) ~= "table" then return nil end
    if type(wire.chapter) == "table" then return wire.chapter end
    local results = wire.results
    if type(results) == "table" and type(results.chapter) == "table" then
        return results.chapter
    end
    if type(wire.contents) == "table" then return wire end
    return nil
end

--- 解码章节页，返回按 ``words`` 排序的图片 URL。
---@param wire table|nil
---@return string[]|nil, string|nil
function Protocol.chapterImages(wire)
    local chapter = chapterRoot(wire)
    if not chapter then return nil, "chapter payload missing" end
    local contents = chapter.contents
    if type(contents) ~= "table" then return nil, "chapter payload missing" end
    local words = type(chapter.words) == "table" and chapter.words or {}
    local pages = {}
    for i, row in ipairs(contents) do
        local url = type(row) == "table" and row.url or nil
        if type(url) == "string" and url:match("^https?://") then
            pages[#pages + 1] = {
                url = url:gsub("%.c800x%.", ".c1500x."),
                order = tonumber(words[i]) or (i - 1),
            }
        end
    end
    table.sort(pages, function(a, b) return a.order < b.order end)
    local images = {}
    for _, page in ipairs(pages) do
        images[#images + 1] = page.url
    end
    if #images == 0 then return nil, "chapter images empty" end
    return images
end

return Protocol
