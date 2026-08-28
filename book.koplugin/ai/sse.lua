--[[--
OpenAI 兼容 SSE 解析：缓冲按行切 data:，冒泡 delta.content。

纯函数，零网络依赖。

@module koplugin.book.ai.sse
--]]

local Content = require("ai.content")
local JSON = require("json")

local SSE = {}

--- 新建 SSE 解析器：feed 吃 chunk，finish 返回全文。
---@return { feed: fun(chunk: string): string|nil, finish: fun(): string }
function SSE.parser()
    local buf = ""
    local full = {}

    --- 解析一行 SSE：空行、注释行、非 data:、[DONE]、坏 JSON 与空 delta 一律返回 nil。
    ---@param line string 已去掉行尾 \r 的单行
    ---@return string|nil 该行携带的正文增量
    local function handleLine(line)
        if line == "" or line:sub(1, 1) == ":" then
            return nil
        end
        local data = line:match("^data:%s?(.*)$")
        if not data then
            return nil
        end
        if data == "[DONE]" then
            return nil
        end
        local ok, decoded = pcall(JSON.decode, data)
        if not ok or type(decoded) ~= "table" then
            return nil
        end
        local choice = decoded.choices and decoded.choices[1]
        local content = Content.fromDelta(choice and choice.delta)
        if not content or content == "" then
            return nil
        end
        return content
    end

    return {
        ---@param chunk string
        ---@return string|nil 本次新冒泡的正文（可能多行合并）
        feed = function(chunk)
            if type(chunk) ~= "string" or chunk == "" then
                return nil
            end
            buf = buf .. chunk
            local pieces = {}
            while true do
                local nl = buf:find("\n", 1, true)
                if not nl then
                    break
                end
                local line = buf:sub(1, nl - 1)
                buf = buf:sub(nl + 1)
                line = line:gsub("\r$", "")
                local text = handleLine(line)
                if text then
                    pieces[#pieces + 1] = text
                    full[#full + 1] = text
                end
            end
            if #pieces == 0 then
                return nil
            end
            return table.concat(pieces)
        end,
        ---@return string
        finish = function()
            if buf ~= "" then
                local text = handleLine(buf:gsub("\r$", ""))
                buf = ""
                if text then
                    full[#full + 1] = text
                end
            end
            return table.concat(full)
        end,
    }
end

return SSE
