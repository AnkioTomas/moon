--[[--
从 OpenAI 兼容 message / delta 提取用户可见正文（仅 content，不含 reasoning）。

@module koplugin.book.ai.content
--]]

local Content = {}

---@param value string|table|nil
---@return string|nil
local function flatten(value)
    if type(value) == "string" then
        return value ~= "" and value or nil
    end
    if type(value) ~= "table" then
        return nil
    end
    local parts = {}
    for _, part in ipairs(value) do
        if type(part) == "string" and part ~= "" then
            parts[#parts + 1] = part
        elseif type(part) == "table" then
            local text = part.text or part.content
            if type(text) == "string" and text ~= "" then
                parts[#parts + 1] = text
            end
        end
    end
    return #parts > 0 and table.concat(parts, "\n") or nil
end

---@param message table|nil
---@return string|nil
function Content.fromMessage(message)
    if type(message) ~= "table" then
        return nil
    end
    return flatten(message.content)
end

---@param delta table|nil
---@return string|nil
function Content.fromDelta(delta)
    if type(delta) ~= "table" then
        return nil
    end
    return flatten(delta.content)
end

return Content
