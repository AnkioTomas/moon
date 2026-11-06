--[[--
知音漫客漫画页。目录不在这份 HTML 里，只取书名和任意一话的文件名。

那一话的地址会 301 到看漫画，真正的章节列表在那边。

@module source.zymk.page
--]]

local Page = {}

---@param html string
---@param property string
---@return string
local function meta(html, property)
    local content = html:match('property="' .. property .. '"%s+content="([^"]*)"')
        or html:match('content="([^"]*)"%s+property="' .. property .. '"')
    return content or ""
end

--- 详情页。没有书名或一话链接就无法定位到看漫画。
---@param html string|nil
---@return table|nil
function Page.detail(html)
    if type(html) ~= "string" or html == "" then return nil end
    local title = meta(html, "og:novel:book_name")
    local chapter_file = html:match('href="(%d+)%.html"')
    if title == "" or not chapter_file then return nil end
    return {
        title = title,
        authors = meta(html, "og:novel:author"),
        cover = meta(html, "og:image"),
        description = meta(html, "og:description"),
        chapter_file = chapter_file,
    }
end

return Page
