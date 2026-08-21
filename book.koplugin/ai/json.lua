--[[--
AI JSON 解码：剥离 Markdown fence，再解析对象。

@module koplugin.book.ai.json
--]]

local JSON = require("json")
local Text = require("utils.text")

local AiJson = {}

--- 剥离 Markdown fence 后解码 JSON 对象。
---@param content string|nil
---@return table|nil, string|nil
function AiJson.decode(content)
    content = Text.trim(content)
    if content == "" then
        return nil, "empty AI response"
    end
    content = content:gsub("^```[%w_%-]*%s*", ""):gsub("%s*```$", "")
    local ok, result = pcall(JSON.decode, content)
    if not ok then
        local first = content:find("{", 1, true)
        local last = content:match(".*()}")
        if first and last and last >= first then
            ok, result = pcall(JSON.decode, content:sub(first, last))
        end
    end
    if not ok or type(result) ~= "table" then
        return nil, "AI did not return JSON"
    end
    return result
end

return AiJson
