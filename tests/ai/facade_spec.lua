--[[-- ai 门面：chat / jsonExtract 契约。 --]]

local Assert = require("support.assert")
local Json = require("support.json_stub")

local settings = { ai_endpoint = "https://example.test/v1", ai_api_key = "k", ai_model = "m" }
package.preload["utils.settings"] = function()
    return { get = function() return settings end }
end
package.preload["json"] = function()
    return { decode = Json.decode, encode = function() return "{}" end }
end

local posted
package.preload["http.request"] = function()
    return {
        post = function(url, body, opts, cb)
            posted = { url = url, body = body, opts = opts }
            cb('{"choices":[{"message":{"content":"{\\"a\\":1}"}}]}', nil, {})
            return { cancel = function() end }
        end,
    }
end

-- 强制重载 client / ai
package.loaded["ai.client"] = nil
package.loaded["ai.json"] = nil
package.loaded["ai"] = nil
package.loaded["ai.init"] = nil

-- 真机插件加载器只注入 book.koplugin/?.lua，不提供 ?/init.lua。
local original_path = package.path
package.path = package.path:gsub("[^;]*/book%.koplugin/%?/init%.lua;?", "")
local loaded, AI = pcall(require, "ai")
package.path = original_path
Assert.is_true(loaded)
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

settings.ai_api_key = ""
Assert.is_false(AI.isConfigured())
