--[[-- ai 门面：chat / chatStream / jsonExtract 契约。 --]]

local Assert = require("support.assert")
local Json = require("support.json_stub")

local settings = { ai_endpoint = "https://example.test/v1", ai_api_key = "k", ai_model = "m" }
package.preload["utils.settings"] = function()
    return { get = function() return settings end }
end
package.preload["json"] = function()
    return { decode = Json.decode, encode = function(v)
        if v.stream then return '{"stream":true}' end
        return '{"stream":false}'
    end }
end

local posted, streamed
package.preload["http.request"] = function()
    return {
        post = function(url, body, opts, cb)
            posted = { url = url, body = body, opts = opts }
            cb('{"choices":[{"message":{"content":"{\\"a\\":1}"}}]}', nil, {})
            return { cancel = function() end }
        end,
        stream = function(opts, handlers)
            streamed = opts
            handlers.on_data('data: {"choices":[{"delta":{"content":"hi"}}]}\n')
            handlers.on_data("data: [DONE]\n")
            handlers.on_done(nil)
            return { cancel = function() end }
        end,
    }
end

-- 强制重载 client / ai
package.loaded["ai.client"] = nil
package.loaded["ai.sse"] = nil
package.loaded["ai.json"] = nil
package.loaded["ai"] = nil
package.loaded["ai.init"] = nil

local AI = require("ai")
Assert.is_true(AI.isConfigured())

local content, err
AI.chat({ { role = "user", content = "x" } }, function(c, e)
    content, err = c, e
end)
Assert.eq(content, '{"a":1}')
Assert.is_nil(err)
Assert.eq(posted.url, "https://example.test/v1/chat/completions")

local extracted
AI.jsonExtract({ { role = "user", content = "x" } }, function(result, e)
    extracted, err = result, e
end)
Assert.eq(extracted.a, 1)

local deltas, full = {}, nil
AI.chatStream({ { role = "user", content = "x" } }, {
    on_delta = function(chunk) deltas[#deltas + 1] = chunk end,
}, function(c, e)
    full, err = c, e
end)
Assert.eq(table.concat(deltas), "hi")
Assert.eq(full, "hi")
Assert.is_nil(err)
Assert.eq(streamed.method, "POST")
Assert.eq(streamed.headers.Accept, "text/event-stream")
Assert.eq(streamed.body, '{"stream":true}')

settings.ai_api_key = ""
Assert.is_false(AI.isConfigured())
