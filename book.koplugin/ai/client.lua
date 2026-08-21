--[[--
OpenAI 兼容 Chat Completions 客户端。只负责协议，不拥有阅读上下文或 UI。

@module koplugin.book.ai.client
--]]

local JSON = require("json")
local Request = require("http.request")
local Settings = require("utils.settings")
local SSE = require("ai.sse")
local Text = require("utils.text")

local Client = {}

--- 规范化 Chat Completions URL；已带路径则原样返回。
---@param base string|nil
---@return string|nil
function Client.endpoint(base)
    base = Text.rtrimSlashes(Text.trim(base))
    if base == "" then return nil end
    if base:match("/chat/completions$") then return base end
    return base .. "/chat/completions"
end

--- 端点、密钥、模型三者齐全才视为已配置。
---@return boolean
function Client.isConfigured()
    local settings = Settings.get()
    return Client.endpoint(settings.ai_endpoint) ~= nil
        and Text.trim(settings.ai_api_key) ~= ""
        and Text.trim(settings.ai_model) ~= ""
end

--- 从 message.content 抽出纯文本（字符串或 text 分片表）。
---@param message table|nil
---@return string|nil
local function contentOf(message)
    local content = message and message.content
    if type(content) == "string" then return content end
    if type(content) ~= "table" then return nil end
    local parts = {}
    for _, part in ipairs(content) do
        if type(part) == "table" and type(part.text) == "string" then
            parts[#parts + 1] = part.text
        end
    end
    return #parts > 0 and table.concat(parts, "\n") or nil
end

--- 解析非流式响应体，返回 choices[1].message 正文。
---@param body string|nil
---@return string|nil, string|nil
function Client.decodeResponse(body)
    local ok, decoded = pcall(JSON.decode, body or "")
    if not ok or type(decoded) ~= "table" then return nil, "invalid AI response" end
    local choice = decoded.choices and decoded.choices[1]
    local content = contentOf(choice and choice.message)
    if not content or content == "" then
        local err = decoded.error
        return nil, type(err) == "table" and tostring(err.message or err.code) or "empty AI response"
    end
    return content
end

---@return string|nil, string|nil, string|nil, string|nil
local function credentials()
    local settings = Settings.get()
    local endpoint = Client.endpoint(settings.ai_endpoint)
    local api_key = Text.trim(settings.ai_api_key)
    local model = Text.trim(settings.ai_model)
    if not endpoint or api_key == "" or model == "" then
        return nil, nil, nil, "AI is not configured"
    end
    return endpoint, api_key, model
end

---@param model string
---@param messages table[]
---@param opts table|nil
---@param stream boolean
---@return string|nil, any
local function encodeBody(model, messages, opts, stream)
    opts = opts or {}
    local payload = {
        model = opts.model or model,
        messages = messages,
        temperature = opts.temperature or 0.2,
        max_tokens = opts.max_tokens or 2000,
    }
    if stream then
        payload.stream = true
    end
    local ok, body = pcall(JSON.encode, payload)
    if not ok then
        return nil, body
    end
    return body
end

--- 非流式 Chat Completions；cb(content, err)。
---@param messages table[]
---@param opts table|nil
---@param cb fun(content: string|nil, err: any)
---@return table|nil
function Client.chat(messages, opts, cb)
    if type(opts) == "function" then
        cb = opts
        opts = nil
    end
    local endpoint, api_key, model, conf_err = credentials()
    if not endpoint then
        cb(nil, conf_err)
        return nil
    end
    local body, enc_err = encodeBody(model, messages, opts, false)
    if not body then
        cb(nil, enc_err)
        return nil
    end
    return Request.post(endpoint, body, {
        content_type = "application/json",
        accept = "application/json",
        timeout = (opts and opts.timeout) or 120,
        headers = { Authorization = "Bearer " .. api_key },
    }, function(response, err, raw)
        if not response then
            local detail
            if raw and type(raw.body) == "string" then
                local decoded_ok, decoded = pcall(JSON.decode, raw.body)
                detail = decoded_ok and type(decoded) == "table" and decoded.error
                detail = type(detail) == "table" and detail.message or nil
            end
            cb(nil, detail or err)
            return
        end
        local content, decode_err = Client.decodeResponse(response)
        cb(content, decode_err)
    end)
end

--- SSE 流式聊天；opts.on_delta 收增量，结束 cb(full, err)。
---@param messages table[]
---@param opts { on_delta?: fun(chunk: string), temperature?: number, max_tokens?: number, model?: string, timeout?: number }
---@param cb fun(content: string|nil, err: any)
---@return table|nil
function Client.chatStream(messages, opts, cb)
    opts = opts or {}
    local endpoint, api_key, model, conf_err = credentials()
    if not endpoint then
        cb(nil, conf_err)
        return nil
    end
    local body, enc_err = encodeBody(model, messages, opts, true)
    if not body then
        cb(nil, enc_err)
        return nil
    end
    local parser = SSE.parser()
    return Request.stream({
        url = endpoint,
        method = "POST",
        body = body,
        timeout = opts.timeout or 180,
        headers = {
            Authorization = "Bearer " .. api_key,
            ["Content-Type"] = "application/json",
            Accept = "text/event-stream",
        },
    }, {
        on_data = function(chunk)
            local delta = parser.feed(chunk)
            if delta and opts.on_delta then
                opts.on_delta(delta)
            end
        end,
        on_done = function(err)
            local full = parser.finish()
            if err then
                cb(full ~= "" and full or nil, err)
                return
            end
            if full == "" then
                cb(nil, "empty AI response")
                return
            end
            cb(full)
        end,
    })
end

return Client
