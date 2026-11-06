--[[--
盐选章节页。正文在页面 JSON 的 `manuscriptData.manuscript`，标签写成 `\\u003c`。

@module source.zhihu.page
--]]

local JSON = require("json")

local Page = {}

---@param html string
---@param from integer
---@param key string
---@return integer|nil
local function field(html, from, key)
    local at = html:find(key, from, true)
    if not at then return nil end
    return at + #key
end

--- 取出正文字符串。折叠章节没有可读正文。
---@param html string|nil
---@return string|nil
---@return string|nil
function Page.manuscript(html)
    if type(html) ~= "string" or html == "" then return nil end
    local data_at = html:find('"manuscriptData":', 1, true)
    if not data_at then return nil end
    local text_at = field(html, data_at, '"manuscript":"')
    if not text_at then return nil end
    local fold_at = html:find('"is_fold":', data_at, true)
    if fold_at and fold_at < text_at and html:sub(fold_at + #'"is_fold":', fold_at + #'"is_fold":' + 3) == "true" then
        return nil, "locked"
    end
    local chars = {}
    local index = text_at
    while index <= #html do
        local char = html:sub(index, index)
        if char == "\\" then
            chars[#chars + 1] = html:sub(index, index + 1)
            index = index + 2
        elseif char == '"' then
            break
        else
            chars[#chars + 1] = char
            index = index + 1
        end
    end
    local ok, text = pcall(JSON.decode, '"' .. table.concat(chars) .. '"')
    if not ok or type(text) ~= "string" or text == "" then return nil end
    return text
end

return Page
