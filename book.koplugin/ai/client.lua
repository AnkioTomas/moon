--[[--
OpenAI 兼容 Chat Completions 客户端。只负责协议，不拥有阅读上下文或 UI。

@module koplugin.book.ai.client
--]]

local JSON = require("json")
local Request = require("http.request")
local Settings = require("utils.settings")
local Text = require("utils.text")
local logger = require("utils.log")

local Client = {}

--- 默认请求超时（秒）；推理模型首包可能较慢。
Client.DEFAULT_TIMEOUT = 120

--- AI 请求默认 User-Agent；部分 OpenAI 兼容网关按 UA 分流/限流。
local DEFAULT_UA = "opencode/1.2.3 ai-sdk/amazon-bedrock/3.0.73 ai-sdk/provider-utils/3.0.20 runtime/bun/1.3.5"

--- 规范化 Chat Completions URL；已带路径则原样返回。
---@param base string|nil
---@return string|nil
function Client.endpoint(base)
    base = Text.rtrimSlashes(Text.trim(base))
    if base == "" then return nil end
    if base:match("/chat/completions$") then return base end
    return base .. "/chat/completions"
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

--- 端点、密钥、模型三者齐全才视为已配置。
---@return boolean
function Client.isConfigured()
    return credentials() ~= nil
end

--- 截断响应体便于日志（首尾截断，控制长度）。
---@param s string|nil
---@param n number
---@return string
local function snip(s, n)
    s = tostring(s or ""):gsub("%s+", " ")
    if #s <= n then
        return s
    end
    return s:sub(1, n) .. ("…(" .. #s .. "B)")
end

--- 提取 message 中用户可见正文（仅 content，不含 reasoning）；数组形式按行拼接。
---@param message table|nil
---@return string|nil
local function messageContent(message)
    local value = type(message) == "table" and message.content
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

--- 解析非流式响应体，返回 choices[1].message 正文。
---@param body string|nil
---@return string|nil, string|nil
function Client.decodeResponse(body)
    local ok, decoded = pcall(JSON.decode, body or "")
    if not ok or type(decoded) ~= "table" then
        return nil, "invalid AI response"
    end
    local choice = decoded.choices and decoded.choices[1]
    local content = messageContent(choice and choice.message)
    if not content then
        local err = decoded.error
        if type(err) == "table" then
            return nil, tostring(err.message or err.code)
        end
        if choice and choice.finish_reason == "length" then
            return nil, "response truncated (max_tokens too low)"
        end
        logger.warn("ai.client: empty content; keys=",
            choice and choice.message and "has-message" or "no-message", "body=", snip(body, 200))
        return nil, "empty AI response"
    end
    return content
end

--- 非流式 Chat Completions；cb(content, err)。
---@param messages table[]
---@param opts table|nil
---@param cb fun(content: string|nil, err: any)
---@return table|nil
function Client.chat(messages, opts, cb)
    opts = opts or {}
    local endpoint, api_key, model, conf_err = credentials()
    if not endpoint then
        cb(nil, conf_err)
        return nil
    end
    local encoded, body = pcall(JSON.encode, {
        model = opts.model or model,
        messages = messages,
        temperature = opts.temperature or 0.2,
        max_tokens = opts.max_tokens or 2000,
    })
    if not encoded then
        cb(nil, body)
        return nil
    end
    -- 连接与整包共用同一预算；推理模型首包可能较慢。
    local timeout = opts.timeout or Client.DEFAULT_TIMEOUT
    return Request.post(endpoint, body, {
        content_type = "application/json",
        accept = "application/json",
        timeout = timeout,
        connect_timeout = opts.connect_timeout or timeout,
        headers = { Authorization = "Bearer " .. api_key, ["User-Agent"] = DEFAULT_UA },
    }, function(response, err, raw)
        if not response then
            local detail
            if raw and type(raw.body) == "string" then
                local decoded_ok, decoded = pcall(JSON.decode, raw.body)
                detail = decoded_ok and type(decoded) == "table" and decoded.error
                detail = type(detail) == "table" and detail.message or nil
            end
            if not detail then
                logger.warn("ai.client: request failed err=", err, "code=",
                    raw and raw.code, "body=", snip(raw and raw.body, 200))
            end
            cb(nil, detail or err)
            return
        end
        local content, decode_err = Client.decodeResponse(response)
        if not content then
            logger.warn("ai.client: decode failed err=", decode_err, "body=", snip(response, 300))
        end
        cb(content, decode_err)
    end)
end

return Client
