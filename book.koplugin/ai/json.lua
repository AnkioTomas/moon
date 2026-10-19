--[[--
AI JSON 解码：剥离 Markdown fence，再解析对象。

@module koplugin.book.ai.json
--]]

require("l10n").apply()

local JSON = require("json")
local Text = require("utils.text")
local logger = require("utils.log")
local _ = require("gettext")

local AiJson = {}

--- 输出被截断的 JSON：丢掉最后一个未写完的元素，补上括号，保住前面已完整的部分。
---@param content string
---@return string|nil
local function closeTruncated(content)
    local first = content:find("{", 1, true)
    if not first then return nil end
    local stack, in_string, escaped = {}, false, false
    local cut, closers = nil, nil
    for i = first, #content do
        local c = content:byte(i)
        if in_string then
            if escaped then escaped = false
            elseif c == 92 then escaped = true
            elseif c == 34 then in_string = false end
        elseif c == 34 then in_string = true
        elseif c == 123 or c == 91 then stack[#stack + 1] = c == 123 and "}" or "]"
        elseif c == 125 or c == 93 then
            stack[#stack] = nil
            -- 每个完整闭合处都是安全截断点，保留最后一个且至少还有一层外层
            if #stack > 0 then
                cut, closers = i, table.concat(stack):reverse()
            end
        end
    end
    if not cut then return nil end
    return content:sub(first, cut) .. closers
end

--- 剥离 Markdown fence 后解码 JSON 对象。
---@param content string|nil
---@param partial boolean|nil 解码失败时按被截断处理，保留已完整的部分
---@return table|nil, string|nil
function AiJson.decode(content, partial)
    content = Text.trim(content)
    if content == "" then
        return nil, _("AI 没有返回内容")
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
    if partial and not ok then
        local closed = closeTruncated(content)
        if closed then
            ok, result = pcall(JSON.decode, closed)
            if ok then logger.warn("ai.json: truncated output, kept complete part") end
        end
    end
    if not ok or type(result) ~= "table" then
        local s = content:gsub("%s+", " ")
        logger.warn("ai.json: not JSON; err=", tostring(result), "content=", s:sub(1, 200), (#content > 200 and "…" or ""))
        return nil, _("AI 返回的内容无法解析")
    end
    return result
end

return AiJson
