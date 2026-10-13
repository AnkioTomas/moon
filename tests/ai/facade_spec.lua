---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

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

-- 前文章节摘要：查到当前章 - 1 为止，按章序拼「章名\n摘要」，缺标题用章号；没有摘要返回 nil
local summary_rows, summary_asked = {}, nil
package.loaded["ai.summary_db"] = {
    upTo = function(source_id, stable_id, max_idx, limit)
        summary_asked = { source_id, stable_id, max_idx, limit }
        return summary_rows
    end,
}
local identity = { source_id = "wechat", stable_id = "b1" }
Assert.is_nil(AI.priorSummaries(identity, 5, 3))
Assert.eq(summary_asked[1], "wechat")
Assert.eq(summary_asked[2], "b1")
Assert.eq(summary_asked[3], 4, "当前章不算前文")
Assert.eq(summary_asked[4], 3)
summary_rows = {
    { chapter_idx = 3, title = "第三章", summary = "他出发了。" },
    { chapter_idx = 4, title = "", summary = "他到了。" },
}
Assert.eq(AI.priorSummaries(identity, 5, 3), "第三章\n他出发了。\n\n#4\n他到了。")
