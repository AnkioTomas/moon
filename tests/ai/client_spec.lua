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
package.preload["http.request"] = function()
    return {
        post = function(url, body, opts, cb)
            sent = { url = url, body = body, opts = opts }
            cb('{"choices":[{"message":{"content":"ok"}}]}', nil, {})
            return { cancel = function() end }
        end,
        stream = function(opts, handlers)
            sent = { url = opts.url, opts = opts }
            handlers.on_done(nil)
            return { cancel = function() end }
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
Assert.eq(encoded.reasoning.enabled, false)
Assert.is_false(encoded.enable_thinking)
Assert.is_false(encoded.chat_template_kwargs.enable_thinking)
Assert.eq(sent.opts.headers.Authorization, "Bearer secret")
Assert.eq(sent.opts.headers["User-Agent"],
    "opencode/1.2.3 ai-sdk/amazon-bedrock/3.0.73 ai-sdk/provider-utils/3.0.20 runtime/bun/1.3.5")
Assert.eq(sent.opts.content_type, "application/json")
Assert.eq(sent.opts.timeout, Client.DEFAULT_TIMEOUT)
Assert.eq(Client.DEFAULT_TIMEOUT, 120)
Assert.eq(content, "ok")
Assert.is_nil(failure)

-- 兼容旧调用：第二参直接传 cb
Client.chat({ { role = "user", content = "hello" } }, function(value, err)
    content, failure = value, err
end)
Assert.eq(content, "ok")
Assert.is_nil(failure)

local array_content = Client.decodeResponse('{"choices":[{"message":{"content":[{"text":"a"},{"text":"b"}]}}]}')
Assert.eq(array_content, "a\nb")
local truncated, trunc_err = Client.decodeResponse('{"choices":[{"finish_reason":"length","message":{"role":"assistant","content":"","reasoning_content":"pong reply"}}]}')
Assert.is_nil(truncated)
Assert.eq(trunc_err, "response truncated (max_tokens too low)")
local missing, err = Client.decodeResponse('{"error":{"message":"bad key"}}')
Assert.is_nil(missing)
Assert.eq(err, "bad key")

-- 流式路径同样带默认 UA
settings.ai_api_key = " secret "
Client.chatStream({ { role = "user", content = "hi" } }, {}, function() end)
Assert.eq(sent.opts.headers["User-Agent"],
    "opencode/1.2.3 ai-sdk/amazon-bedrock/3.0.73 ai-sdk/provider-utils/3.0.20 runtime/bun/1.3.5")

settings.ai_api_key = ""
Assert.is_false(Client.isConfigured())
