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
Assert.is_nil(encoded.reasoning)
Assert.is_nil(encoded.enable_thinking)
Assert.eq(encoded.chat_template_kwargs.enable_thinking, false, "默认关掉混合推理模型的思考")
Assert.eq(sent.opts.headers.Authorization, "Bearer secret")
Assert.eq(sent.opts.headers["User-Agent"],
    "opencode/1.2.3 ai-sdk/amazon-bedrock/3.0.73 ai-sdk/provider-utils/3.0.20 runtime/bun/1.3.5")
Assert.eq(sent.opts.content_type, "application/json")
Assert.eq(sent.opts.timeout, Client.DEFAULT_TIMEOUT)
Assert.eq(sent.opts.connect_timeout, Client.DEFAULT_TIMEOUT)
Assert.eq(Client.DEFAULT_TIMEOUT, 120)
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
Assert.eq(posts[2].payload.max_tokens, 8000)
Assert.is_nil(content)
Assert.eq(failure, "response truncated (max_tokens too low)")
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
Assert.eq(failure, "Unrecognized request argument")
replies, posts = { "hold" }, {}
local handle = Client.chat({ { role = "user", content = "hello" } }, nil, function() error("cancelled request must not call back") end)
handle:cancel()
Assert.is_true(posts[1].cancelled)
settings.ai_endpoint = " https://example.test/v1/ "

local array_content = Client.decodeResponse('{"choices":[{"message":{"content":[{"text":"a"},{"text":"b"}]}}]}')
Assert.eq(array_content, "a\nb")
local truncated, trunc_err = Client.decodeResponse('{"choices":[{"finish_reason":"length","message":{"role":"assistant","content":"","reasoning_content":"pong reply"}}]}')
Assert.is_nil(truncated)
Assert.eq(trunc_err, "response truncated (max_tokens too low)")
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
local empty, empty_err = Client.decodeResponse('{"choices":[{"message":{"content":"","reasoning_content":"think"}}]}')
Assert.is_nil(empty)
Assert.eq(empty_err, "empty AI response")
Assert.is_nil(Client.decodeResponse('{"choices":[{"message":{"reasoning_details":[{"text":"via details"}]}}]}'))

settings.ai_api_key = ""
Assert.is_false(Client.isConfigured())
