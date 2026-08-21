--[[--
可复用 AI 能力门面：chat / chatStream / jsonExtract。

其它模块统一 require("ai")，不要直连 client。

@module koplugin.book.ai
--]]

local AiJson = require("ai.json")
local Client = require("ai.client")

local AI = {}

---@return boolean
function AI.isConfigured()
    return Client.isConfigured()
end

--- 非流式聊天；cb(content, err)。
---@param messages table[]
---@param opts table|nil
---@param cb fun(content: string|nil, err: any)
---@return table|nil
function AI.chat(messages, opts, cb)
    if type(opts) == "function" then
        cb = opts
        opts = nil
    end
    return Client.chat(messages, opts, cb)
end

--- SSE 流式聊天；opts.on_delta(chunk)；结束 cb(full, err)。
---@param messages table[]
---@param opts { on_delta?: fun(chunk: string), temperature?: number, max_tokens?: number, model?: string, timeout?: number }
---@param cb fun(content: string|nil, err: any)
---@return table|nil
function AI.chatStream(messages, opts, cb)
    return Client.chatStream(messages, opts, cb)
end

--- 非流式 JSON 抽取；cb(table|nil, err)。
---@param messages table[]
---@param opts table|nil
---@param cb fun(result: table|nil, err: any)
---@return table|nil
function AI.jsonExtract(messages, opts, cb)
    if type(opts) == "function" then
        cb = opts
        opts = nil
    end
    return Client.chat(messages, opts, function(content, err)
        if not content then
            cb(nil, err)
            return
        end
        local result, decode_err = AiJson.decode(content)
        cb(result, decode_err)
    end)
end

AI.decodeJson = AiJson.decode

return AI
