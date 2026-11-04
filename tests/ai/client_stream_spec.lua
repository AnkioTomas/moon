-- ai.client：SSE 流式拼装。
local Assert = require("support.assert")
package.preload["utils.settings"] = function()
    return { get = function() return { ai_endpoint = "https://example.test/v1", ai_api_key = "k", ai_model = "m" } end }
end
package.preload["json"] = function() return require("support.json_stub") end
local req
package.preload["http.request"] = function()
    return { stream = function(opts, handlers) req = { opts = opts, h = handlers }; return { cancel = function() end } end }
end
local Client = require("ai.client")

local content, failure
Client.chat({ { role = "user", content = "hi" } }, { stream = true }, function(c, e) content, failure = c, e end)
Assert.is_true(req.opts.method == "POST")
Assert.matches(req.opts.body, '"stream":true')
req.h.on_headers(200, {})
req.h.on_data('data: {"choices":[{"delta":{"reasoning_content":"think"}}]}\n\ndata: {"choices":[{"delta":{"con')
req.h.on_data('tent":"{\\"a\\":"}}]}\r\n\r\ndata: {"choices":[{"delta":{"content":"1}"},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n')
req.h.on_done(nil)
Assert.eq(content, '{"a":1}')
Assert.is_nil(failure)

-- 服务端忽略 stream，直接给整段 JSON
content = nil
Client.chat({ { role = "user", content = "hi" } }, { stream = true }, function(c, e) content, failure = c, e end)
req.h.on_headers(200, {})
req.h.on_data('{"choices":[{"message":{"content":"plain"}}]}')
req.h.on_done(nil)
Assert.eq(content, "plain")

-- 连接错误
content, failure = nil, nil
Client.chat({ { role = "user", content = "hi" } }, { stream = true }, function(c, e) content, failure = c, e end)
req.h.on_done("timeout")
Assert.is_nil(content)
Assert.is_true(failure ~= nil)
