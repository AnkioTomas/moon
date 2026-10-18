--[[--
OpenAI 兼容 Chat Completions 客户端。只负责协议，不拥有阅读上下文或 UI。

@module koplugin.book.ai.client
--]]

require("l10n").apply()

local JSON = require("json")
local Request = require("http.request")
local Settings = require("utils.settings")
local Text = require("utils.text")
local logger = require("utils.log")
local _ = require("gettext")

local Client = {}

--- 默认请求超时（秒）；推理模型首包可能较慢。
Client.DEFAULT_TIMEOUT = 120

--- AI token 上限的内置默认值（生成 token 数）；调用方未显式传 max_tokens 时用。
Client.DEFAULT_MAX_TOKENS = 4000

--- AI 请求默认 User-Agent；部分 OpenAI 兼容网关按 UA 分流/限流。
local DEFAULT_UA = "opencode/1.2.3 ai-sdk/amazon-bedrock/3.0.73 ai-sdk/provider-utils/3.0.20 runtime/bun/1.3.5"

local TRUNCATED = _("回答被截断：输出长度上限不够")
--- 截断后放大重试的上限：常见模型的输出上限在 8K～16K，再大端点会直接 400。
local RETRY_MAX_TOKENS = 16384

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
    local settings = Settings.get("ai")
    local endpoint = Client.endpoint(settings.ai_endpoint)
    local api_key = Text.trim(settings.ai_api_key)
    local model = Text.trim(settings.ai_model)
    if not endpoint or api_key == "" or model == "" then
        return nil, nil, nil, _("AI 未配置")
    end
    return endpoint, api_key, model
end

--- 端点、密钥、模型三者齐全才视为已配置。
---@return boolean
function Client.isConfigured()
    return credentials() ~= nil
end

--- AI token 上限：优先取 ai_max_tokens 配置，非法或缺失时回退 DEFAULT_MAX_TOKENS。
---@return integer
function Client.defaultMaxTokens()
    local configured = tonumber(Settings.get("ai").ai_max_tokens)
    if configured and configured > 0 then
        return math.floor(configured)
    end
    return Client.DEFAULT_MAX_TOKENS
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

--- 提取 message 中用户可见正文（只取 content，reasoning_content 等推理字段一律不要）；数组形式按行拼接。
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
    for _idx, part in ipairs(value) do
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

--- 去掉混在正文里的思考过程：部分推理模型 / 网关把它包在 <think>…</think> 里放进 content
--- （有时只剩结尾标签），只留标签之后的回答。有开头标签没结尾的是思考写到一半被截断，没有回答。
---@param content string
---@return string|nil
local function dropThinking(content)
    local answer = content:match("</think>%s*(.*)$")
    if not answer and content:match("^%s*<think>") then return nil end
    answer = answer or content
    return answer ~= "" and answer or nil
end

--- 解析非流式响应体，返回 choices[1].message 正文。
---@param body string|nil
---@return string|nil, string|nil
function Client.decodeResponse(body)
    local ok, decoded = pcall(JSON.decode, body or "")
    if not ok or type(decoded) ~= "table" then
        return nil, _("AI 返回的内容无法解析")
    end
    local choice = decoded.choices and decoded.choices[1]
    local content = messageContent(choice and choice.message)
    content = content and dropThinking(content)
    if not content then
        local err = decoded.error
        if type(err) == "table" then
            return nil, tostring(err.message or err.code)
        end
        if choice and choice.finish_reason == "length" then
            return nil, TRUNCATED
        end
        logger.warn("ai.client: empty content; keys=",
            choice and choice.message and "has-message" or "no-message", "body=", snip(body, 200))
        return nil, _("AI 没有返回内容")
    end
    return content
end

--- 端点不认 chat_template_kwargs（返回过 400 / 422）的，本进程内不再带。
local no_think_param = {}

--- 处理一次 Chat Completions 响应，返回 content, err。
---@param response string|nil
---@param err any
---@param raw table|nil
---@return string|nil, any
local function finish(response, err, raw)
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
        return nil, detail or err
    end
    local content, decode_err = Client.decodeResponse(response)
    if not content then
        logger.warn("ai.client: decode failed err=", decode_err, "body=", snip(response, 300))
    end
    return content, decode_err
end

local KEEP_NAMES = "實體名稱（name、aliases）須與書中原文逐字一致，不做簡繁或語言轉換；只有敘述性文字使用指定語言。"
local KEEP_NAMES_EN = " Entity names (name, aliases) must match the book text verbatim, without translation or script conversion; only descriptive text uses the chosen language."

--- AI 回答语言 / 地区风格（有序，设置页按此列出）。label 是各语言自称，不走翻译；name 替换提示词里写死的「简体中文」。
Client.LANGUAGES = {
    { id = "zh_CN", label = "简体中文（中国大陆）", name = "简体中文",
        rule = "\n\n一律使用简体中文与中国大陆通行用语，不要使用繁体字。实体名称（name、aliases）须与书中原文逐字一致，不做简繁或语言转换；只有叙述性文字使用指定语言。" },
    { id = "zh_TW", label = "繁體中文（台灣）", name = "繁體中文",
        rule = "\n\n一律使用繁體中文與台灣慣用語（例如「軟體」「資訊」「網路」「品質」），不要使用簡體字或大陸用語。" .. KEEP_NAMES },
    { id = "zh_HK", label = "繁體中文（香港）", name = "繁體中文",
        rule = "\n\n一律使用繁體中文與香港慣用語，不要使用簡體字或大陸用語。" .. KEEP_NAMES },
    { id = "en_US", label = "English (US)", name = "English",
        rule = "\n\nAlways reply in natural American English, with American spelling and idioms." .. KEEP_NAMES_EN },
    { id = "en_GB", label = "English (UK)", name = "English",
        rule = "\n\nAlways reply in natural British English, with British spelling and idioms." .. KEEP_NAMES_EN },
}

--- 界面语言（l10n 目录名）对应的默认回答语言；其它界面语言不加约束。
local FOLLOW_UI = { zh_CN = "zh_CN", zh_TW = "zh_TW", en = "en_US" }

--- 当前回答语言条目：设置 ai_language（缺省 / auto = 跟随界面语言）；跟随到没有对应条目时为 nil。
---@return table|nil
function Client.language()
    local id = Settings.get("ai").ai_language
    if not id or id == "auto" then id = FOLLOW_UI[require("l10n").catalog()] end
    for _idx, lang in ipairs(Client.LANGUAGES) do
        if lang.id == id then return lang end
    end
end

--- opts.localize 时：system 提示词按回答语言替换写死的语言名并追加语言 / 用语要求（提示词本身是简体源串）。
---@param messages table[]
---@return table[]
local function localize(messages)
    local lang = Client.language()
    if not lang then return messages end
    local out = {}
    for idx, message in ipairs(messages) do
        if message.role == "system" then
            local copy = {}
            for k, v in pairs(message) do copy[k] = v end
            copy.content = message.content:gsub("简体中文", lang.name) .. lang.rule
            message = copy
        end
        out[idx] = message
    end
    return out
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
    -- 连接与整包共用同一预算；推理模型首包可能较慢。
    -- 调用方用 Timeout.ai(倍率) 传入；不传 = 「AI 请求超时」本身。
    local timeout = opts.timeout or require("http.timeout").ai()
    local max_tokens = opts.max_tokens or Client.defaultMaxTokens()
    local current, cancelled
    if opts.localize then messages = localize(messages) end

    ---@param think_off boolean
    ---@param budget number
    ---@return table|nil
    local function send(think_off, budget)
        local payload = {
            model = opts.model or model,
            messages = messages,
            temperature = opts.temperature or 0.2,
            max_tokens = budget,
        }
        -- Qwen3.5 这类混合推理模型默认先写一大段思考，吃光 max_tokens，回答被截断。
        if think_off then payload.chat_template_kwargs = { enable_thinking = false } end
        local encoded, body = pcall(JSON.encode, payload)
        if not encoded then
            cb(nil, body)
            return nil
        end
        return Request.post(endpoint, body, {
            content_type = "application/json",
            accept = "application/json",
            timeout = timeout,
            connect_timeout = opts.connect_timeout or timeout,
            headers = { Authorization = "Bearer " .. api_key, ["User-Agent"] = DEFAULT_UA },
        }, function(response, err, raw)
            if cancelled then return end
            -- OpenAI 官方等严格端点不认这个参数会 400 / 422：去掉重发，本进程内记住。
            -- 只认原始额度那一轮：放大额度后的 400 多半是 max_tokens 超出模型上限，与这个参数无关。
            if not response and think_off and budget == max_tokens and raw
                    and (raw.code == 400 or raw.code == 422) then
                no_think_param[endpoint] = true
                current = send(false, budget)
                return
            end
            local content, fail = finish(response, err, raw)
            -- 关不掉思考的推理模型会把上限吃光、正文为空：放大到 4 倍（封顶）重试一次。
            local enlarged = math.min(max_tokens * 4, RETRY_MAX_TOKENS)
            if fail == TRUNCATED and budget == max_tokens and enlarged > budget then
                current = send(think_off, enlarged)
                return
            end
            cb(content, fail)
        end)
    end

    current = send(not no_think_param[endpoint], max_tokens)
    if not current then return nil end
    return { cancel = function()
        cancelled = true
        if current then current:cancel() end
    end }
end

return Client
