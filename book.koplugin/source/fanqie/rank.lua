--[[--
番茄网页榜单：解析榜单页内嵌的 __INITIAL_STATE__。书名 / 简介是 PUA 混淆字体，解码表同正文。

@module koplugin.book.source.fanqie.rank
--]]

local Content = require("source.fanqie.content")
local FanQie = require("source.fanqie.fanqie")
local JSON = require("json")

local Rank = {}

--- 榜单页 HTML → 榜单状态（book_list、rankCategoryTypeList）。脚本是 `(function(){ window.__INITIAL_STATE__={...}; })()`，
--- 里面有裸 `undefined`，不是合法 JSON。
---@param html string
---@return table|nil rank
function Rank.state(html)
    local script = html:match("__INITIAL_STATE__=(.-)</script>")
    local body = script and script:gsub("([:,%[])undefined", "%1null"):match("^(.*})%s*;%s*}%s*%)%s*%(%s*%)%s*$")
    local ok, state = pcall(JSON.decode, body or "")
    return ok and type(state) == "table" and state.rank or nil
end

---@param rank table Rank.state 的结果
---@param source_id string
---@return Book[]
function Rank.books(rank, source_id)
    local books = {}
    for _idx, row in ipairs(rank.book_list or {}) do
        books[#books + 1] = {
            source_id = source_id,
            stable_id = tostring(row.bookId),
            title = Content.decode_pua_content(row.bookName),
            authors = row.author or "",
            intro = Content.decode_pua_content(row.abstract),
            cover = FanQie.mobileCover(row.thumbUri),
        }
    end
    return books
end

return Rank
