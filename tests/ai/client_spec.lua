--[[-- ai.client：配置校验与 Chat Completions 协议。 --]]

local Assert = require("support.assert")
local Json = require("support.json_stub")

local settings = { ai_endpoint = " https://example.test/v1/ ", ai_api_key = " secret ", ai_model = "model-x" }
package.preload["utils.settings"] = function() return { get = function() return settings end } end
local sent
local encoded
package.preload["json"] = function()
    return {
        encode = function(value)
            encoded = value
            return value.model
        end,
        decode = Json.decode,
    }
end
local replies, posts = {}, {}
package.preload["http.request"] = function()
    return {
        post = function(url, body, opts, cb)
            sent = { url = url, body = body, opts = opts, payload = encoded }
            posts[#posts + 1] = sent
            local reply = table.remove(replies, 1)
            if reply == "hold" then
                sent.cb = cb
            elseif reply == "length" then
                cb('{"choices":[{"finish_reason":"length","message":{"content":"","reasoning_content":"..."}}]}', nil, {})
            elseif type(reply) == "table" then
                cb(nil, "HTTP " .. reply[1], { code = reply[1], body = reply[2] })
            elseif reply then
                cb(nil, "HTTP " .. reply, { code = reply, body = '{"error":{"message":"Unrecognized request argument"}}' })
            else
                cb('{"choices":[{"message":{"content":"ok"}}]}', nil, {})
            end
            local job = sent
            return { cancel = function() job.cancelled = true end }
        end,
    }
end

local Client = require("ai.client")
Assert.eq(Client.endpoint("https://x/v1/"), "https://x/v1/chat/completions")
Assert.eq(Client.endpoint("https://x/v1/chat/completions"), "https://x/v1/chat/completions")
Assert.is_nil(Client.endpoint("  "))
Assert.is_true(Client.isConfigured())

local content, failure
Client.chat({ { role = "user", content = "hello" } }, nil, function(value, err)
    content, failure = value, err
end)
Assert.eq(sent.url, "https://example.test/v1/chat/completions")
Assert.eq(sent.body, "model-x")
Assert.is_nil(encoded.enable_thinking)
Assert.eq(encoded.chat_template_kwargs.enable_thinking, false, "认不出服务商：两种写法都发")
Assert.eq(encoded.reasoning.enabled, false)
Assert.eq(sent.opts.headers.Authorization, "Bearer secret")
Assert.eq(sent.opts.headers["User-Agent"],
    "opencode/1.2.3 ai-sdk/amazon-bedrock/3.0.73 ai-sdk/provider-utils/3.0.20 runtime/bun/1.3.5")
Assert.eq(sent.opts.content_type, "application/json")
Assert.eq(sent.opts.timeout, 120, "http.timeout.ai 默认 120s：推理模型首包可能较慢")
Assert.eq(sent.opts.connect_timeout, 120)
Assert.eq(content, "ok")
Assert.is_nil(failure)

-- 严格端点不认 chat_template_kwargs（400）：去掉重发一次，本进程内不再带
replies, posts = { 400 }, {}
Client.chat({ { role = "user", content = "hello" } }, nil, function(value, err) content, failure = value, err end)
Assert.len(posts, 2)
Assert.not_nil(posts[1].payload.chat_template_kwargs)
Assert.is_nil(posts[2].payload.chat_template_kwargs)
Assert.eq(content, "ok")
posts = {}
Client.chat({ { role = "user", content = "hello" } }, nil, function() end)
Assert.len(posts, 1)
Assert.is_nil(posts[1].payload.chat_template_kwargs)

-- 推理把上限吃光、正文为空：按 4 倍上限重试一次
replies, posts = { "length" }, {}
Client.chat({ { role = "user", content = "hello" } }, { max_tokens = 800 }, function(value, err)
    content, failure = value, err
end)
Assert.len(posts, 2)
Assert.eq(posts[1].payload.max_tokens, 800)
Assert.eq(posts[2].payload.max_tokens, 3200)
Assert.eq(content, "ok")
Assert.is_nil(failure)
replies, posts = { "length", "length" }, {}
Client.chat({ { role = "user", content = "hello" } }, nil, function(value, err) content, failure = value, err end)
Assert.len(posts, 2, "只重试一次")
Assert.eq(posts[1].payload.max_tokens, 8000, "默认走回答上限")
Assert.eq(posts[2].payload.max_tokens, 32000, "4 倍放大")
Assert.is_nil(content)
Assert.eq(failure, "回答被截断：输出长度上限不够")
replies, posts = { "length" }, {}
Client.chat({ { role = "user", content = "hello" } }, { max_tokens = 10000 }, function() end)
Assert.eq(posts[2].payload.max_tokens, 32768, "放大重试封顶")
replies, posts = { "length" }, {}
Client.chat({ { role = "user", content = "hello" } }, { max_tokens = 40000 }, function(value, err)
    content, failure = value, err
end)
Assert.len(posts, 1, "已到封顶不再重试")
Assert.eq(failure, "回答被截断：输出长度上限不够")
replies, posts = { "length", "hold" }, {}
local retry_handle = Client.chat({ { role = "user", content = "hello" } }, nil,
    function() error("cancelled retry must not call back") end)
retry_handle:cancel()
Assert.len(posts, 2)
Assert.is_true(posts[2].cancelled, "取消的是重试那条")

-- 其它失败照常报错，不重发；取消后不再回调
settings.ai_endpoint = "https://other.test/v1"
replies, posts = { 401 }, {}
Client.chat({ { role = "user", content = "hello" } }, nil, function(value, err) content, failure = value, err end)
Assert.len(posts, 1)
Assert.is_nil(content)
Assert.eq(failure, "HTTP 401 Unrecognized request argument")
replies, posts = { "hold" }, {}
local handle = Client.chat({ { role = "user", content = "hello" } }, nil, function() error("cancelled request must not call back") end)
handle:cancel()
Assert.is_true(posts[1].cancelled)
-- 取消不掉的请求（句柄是空操作）回包后也不回调
replies, posts = { "hold" }, {}
handle = Client.chat({ { role = "user", content = "hello" } }, nil, function() error("cancelled request must not call back") end)
handle:cancel()
posts[1].cb('{"choices":[{"message":{"content":"late"}}]}', nil, {})

-- OpenRouter：message 只有 "Provider returned error"，上游原话在 metadata.raw
do
    settings.ai_endpoint = "https://or.test/v1"
    replies, posts = { { 429, '{"error":{"message":"Provider returned error","metadata":{"raw":"rate limited"}}}' } }, {}
    Client.chat({ { role = "user", content = "hello" } }, nil, function(_value, err) failure = err end)
    Assert.eq(failure, "HTTP 429 Provider returned error: rate limited")
end

-- 放大额度后的 400 是额度超上限，不是端点不认关思考参数
settings.ai_endpoint = "https://third.test/v1"
replies, posts = { "length", 400 }, {}
Client.chat({ { role = "user", content = "hello" } }, { max_tokens = 800 }, function(value, err)
    content, failure = value, err
end)
Assert.len(posts, 2)
Assert.eq(failure, "HTTP 400 Unrecognized request argument")
posts = {}
Client.chat({ { role = "user", content = "hello" } }, nil, function() end)
Assert.not_nil(posts[1].payload.chat_template_kwargs, "仍然关思考")
settings.ai_endpoint = " https://example.test/v1/ "

local array_content = Client.decodeResponse('{"choices":[{"message":{"content":[{"text":"a"},{"text":"b"}]}}]}')
Assert.eq(array_content, "a\nb")
local truncated, trunc_err = Client.decodeResponse('{"choices":[{"finish_reason":"length","message":{"role":"assistant","content":"","reasoning_content":"pong reply"}}]}')
Assert.is_nil(truncated)
Assert.eq(trunc_err, "回答被截断：输出长度上限不够")
local missing, err = Client.decodeResponse('{"error":{"message":"bad key"}}')
Assert.is_nil(missing)
Assert.eq(err, "bad key")

-- 只取 content，不回退到 reasoning 字段
Assert.eq(Client.decodeResponse('{"choices":[{"message":{"content":"hello"}}]}'), "hello")
Assert.eq(Client.decodeResponse('{"choices":[{"message":{"content":"out","reasoning_content":"think"}}]}'), "out")
-- 混在正文里的思考过程（含只剩结尾标签的）去掉；只有思考没有回答算空回复
Assert.eq(Client.decodeResponse('{"choices":[{"message":{"content":"<think>先想想</think>\\n\\n回答"}}]}'), "回答")
Assert.eq(Client.decodeResponse('{"choices":[{"message":{"content":"想了一半</think>回答"}}]}'), "回答")
local thinking_only = Client.decodeResponse('{"choices":[{"message":{"content":"<think>只有思考</think>"}}]}')
Assert.is_nil(thinking_only)
-- 思考写到一半就到上限：没有回答，按截断处理（会触发放大重试）
local half, half_err = Client.decodeResponse(
    '{"choices":[{"finish_reason":"length","message":{"content":"<think>想到一半"}}]}')
Assert.is_nil(half)
Assert.eq(half_err, "回答被截断：输出长度上限不够")
local empty, empty_err = Client.decodeResponse('{"choices":[{"message":{"content":"","reasoning_content":"think"}}]}')
Assert.is_nil(empty)
Assert.eq(empty_err, "AI 没有返回内容")
Assert.is_nil(Client.decodeResponse('{"choices":[{"message":{"reasoning_details":[{"text":"via details"}]}}]}'))

settings.ai_api_key = ""
Assert.is_false(Client.isConfigured())

-- 繁体界面 + localize：system 提示词改要求繁體中文，其余消息与默认路径不动
settings.ai_api_key = "secret"
local GetText = require("gettext")
local old_lang = GetText.current_lang
GetText.current_lang = "zh_TW"
posts = {}
Client.chat({ { role = "system", content = "用简体中文回答" }, { role = "user", content = "hi" } },
    { localize = true }, function() end)
Assert.matches(posts[1].payload.messages[1].content, "繁體中文回答")
Assert.matches(posts[1].payload.messages[1].content, "台灣慣用語")
Assert.eq(posts[1].payload.messages[2].content, "hi")
posts = {}
Client.chat({ { role = "system", content = "用简体中文回答" } }, nil, function() end)
Assert.eq(posts[1].payload.messages[1].content, "用简体中文回答")
GetText.current_lang = old_lang

-- 回答语言：显式选择优先于界面语言；英文替换写死的语言名；auto 跟随界面
GetText.current_lang = "zh_CN"
settings.ai_language = "en_GB"
posts = {}
Client.chat({ { role = "system", content = "用简体中文回答" } }, { localize = true }, function() end)
Assert.matches(posts[1].payload.messages[1].content, "^用English回答")
Assert.matches(posts[1].payload.messages[1].content, "British English")
settings.ai_language = "auto"
posts = {}
Client.chat({ { role = "system", content = "用简体中文回答" } }, { localize = true }, function() end)
Assert.matches(posts[1].payload.messages[1].content, "中国大陆")
settings.ai_language = nil
GetText.current_lang = old_lang

-- 服务商：auto 按接口地址认；手选优先；「不发送」不带任何关思考字段
local function think_payload(endpoint, provider)
    settings.ai_endpoint, settings.ai_provider = endpoint, provider
    posts = {}
    Client.chat({ { role = "user", content = "x" } }, nil, function() end)
    return posts[1].payload
end
local p = think_payload("https://openrouter.ai/api/v1", nil)
Assert.eq(p.reasoning.enabled, false)
Assert.is_nil(p.chat_template_kwargs)
p = think_payload("https://api.deepseek.com/v1", "auto")
Assert.eq(p.thinking.type, "disabled")
p = think_payload("https://dashscope.aliyuncs.com/compatible-mode/v1", "auto")
Assert.eq(p.enable_thinking, false)
p = think_payload("https://vllm.test/v1", "vllm")
Assert.eq(p.chat_template_kwargs.enable_thinking, false)
Assert.is_nil(p.reasoning)
p = think_payload("https://openrouter.ai/api/v1", "none")
Assert.is_nil(p.reasoning)
Assert.is_nil(p.thinking)
settings.ai_provider = nil
