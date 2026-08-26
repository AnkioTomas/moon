--[[-- xray.analysis：结构化结果清洗、缓存和持久化。 --]]

local Assert = require("support.assert")
local Json = require("support.json_stub")

local saved, existing
package.preload["json"] = function()
    return {
        decode = Json.decode,
        encode = function(value) saved = value; return "encoded" end,
    }
end
package.preload["utils.db.ai"] = function()
    return {
        get = function() return existing end,
        upsert = function(...) saved.upsert = { ... }; return true end,
        allForBook = function() return {} end,
    }
end
package.preload["xray.context"] = function()
    return { visibleText = function() return "正文", 12 end }
end
local chat_calls = 0
package.preload["ai"] = function()
    return {
        jsonExtract = function(_, _, cb)
            chat_calls = chat_calls + 1
            cb({
                summary = "摘要",
                analysis = "分析",
                characters = { { name = "甲", role = "主角", description = "行动" } },
                events = { { name = "相遇", description = "甲遇见乙", participants = { "甲", "乙" } } },
                relations = { { from = "甲", to = "乙", type = "同伴", description = "同行" } },
            })
        end,
    }
end
package.preload["ai.json"] = function()
    return {
        decode = function(content)
            content = tostring(content or "")
            content = content:gsub("^```[%w_%-]*%s*", ""):gsub("%s*```$", "")
            local ok, result = pcall(Json.decode, content)
            if not ok then
                local first = content:find("{", 1, true)
                local last = content:match(".*()}")
                if first and last and last >= first then
                    ok, result = pcall(Json.decode, content:sub(first, last))
                end
            end
            if not ok or type(result) ~= "table" then return nil, "AI did not return JSON" end
            return result
        end,
    }
end
package.preload["utils.db.queue"] = function()
    return { run = function(worker, opts) worker(); opts.on_done() end }
end
package.preload["ffi/sha2"] = function() return { md5 = function() return "context-key" end } end

local Analysis = require("xray.analysis")
local decoded = assert(Analysis.decode('{"summary":" s ","analysis":" a ","characters":[],"events":[],"relations":[]}'))
Assert.eq(decoded.summary, "s")
Assert.eq(decoded.analysis, "a")
Assert.is_nil(Analysis.decode("not json"))
local with_braces = assert(Analysis.decode('prefix {"summary":"含 { 符号","analysis":"ok","characters":[],"events":[],"relations":[]} suffix'))
Assert.eq(with_braces.summary, "含 { 符号")

local filtered = assert(Analysis.decode('{"summary":"有","analysis":"","characters":[{"name":"","role":"","description":""}],"events":[{"name":"","description":""}],"relations":[{"from":"","to":"","type":"","description":""}]}'))
Assert.eq(filtered.summary, "有")
Assert.len(filtered.characters, 0)
Assert.len(filtered.events, 0)
Assert.len(filtered.relations, 0)

local partial = assert(Analysis.decode('{"summary":"","analysis":"","characters":[{"name":"","role":"旁白","description":""}],"events":[],"relations":[{"from":"","to":"乙","type":"","description":""}]}'))
Assert.len(partial.characters, 1)
Assert.eq(partial.characters[1].role, "旁白")
Assert.len(partial.relations, 1)
Assert.eq(partial.relations[1].to, "乙")

local result, failure, was_cached
local identity = { source_id = "moon", stable_id = "book", chapter_idx = 2, book = { title = "T" } }
Analysis.run({}, identity, nil, function(value, err, cached)
    result, failure, was_cached = value, err, cached
end)
Assert.eq(chat_calls, 1)
Assert.eq(result.summary, "摘要")
Assert.eq(result.characters[1].name, "甲")
Assert.eq(saved.upsert[1], "moon")
Assert.eq(saved.upsert[2], "book")
Assert.eq(saved.upsert[3], 2)
Assert.eq(saved.upsert[4], "context-key")
Assert.eq(saved.upsert[5], 12)
Assert.eq(saved.upsert[6], "encoded")
Assert.is_nil(failure)
Assert.is_false(was_cached)

existing = { payload = '{"summary":"缓存","analysis":"","characters":[],"events":[],"relations":[]}' }
Analysis.run({}, identity, nil, function(value, err, cached)
    result, failure, was_cached = value, err, cached
end)
Assert.eq(chat_calls, 1)
Assert.eq(result.summary, "缓存")
Assert.is_true(was_cached)
