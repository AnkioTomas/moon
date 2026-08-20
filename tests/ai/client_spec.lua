--[[-- ai.client：配置校验与 Chat Completions 协议。 --]]

local Assert = require("support.assert")
local Json = require("support.json_stub")

local settings = { ai_endpoint = " https://example.test/v1/ ", ai_api_key = " secret ", ai_model = "model-x" }
package.preload["utils.settings"] = function() return { get = function() return settings end } end
package.preload["json"] = function()
    return { encode = function(value) return value.model end, decode = Json.decode }
end

local sent
package.preload["http.request"] = function()
    return { post = function(url, body, opts, cb)
        sent = { url = url, body = body, opts = opts }
        cb('{"choices":[{"message":{"content":"ok"}}]}', nil, {})
        return { cancel = function() end }
    end }
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
Assert.eq(sent.opts.headers.Authorization, "Bearer secret")
Assert.eq(sent.opts.content_type, "application/json")
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
local missing, err = Client.decodeResponse('{"error":{"message":"bad key"}}')
Assert.is_nil(missing)
Assert.eq(err, "bad key")

settings.ai_api_key = ""
Assert.is_false(Client.isConfigured())
