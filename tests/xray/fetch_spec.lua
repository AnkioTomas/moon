--[[-- xray.fetch：mock AI.jsonExtract，校验初始化/增量两条路径与合并落库。 --]]

local Assert = require("support.assert")
local Json = require("support.json_stub")

package.preload["json"] = function()
    return { decode = Json.decode, encode = Json.encode }
end

local entity_rows = {}
package.preload["db.xray"] = function()
    return {
        list = function(source_id, stable_id, kind)
            local out = {}
            for index, row in ipairs(entity_rows) do
                if not kind or row.kind == kind then
                    out[#out + 1] = row
                end
            end
            return out
        end,
        replace = function(source_id, stable_id, entities)
            entity_rows = {}
            for index, entity in ipairs(entities) do
                entity_rows[#entity_rows + 1] = entity
            end
            return true
        end,
    }
end
package.preload["xray.context"] = function()
    return {
        forAnalysis = function()
            return {
                current_page = "Mina at Whitby saw Dracula",
                prior_text = "prior",
                page = 5,
            }
        end,
        currentPage = function() return 5 end,
    }
end
package.preload["ui.reader.session"] = function()
    return { current = function() return { percent = 42 } end }
end

--- 每次调用按顺序吐一个预设响应，并记下 prompt。
local replies, prompts = {}, {}
package.preload["ai"] = function()
    return {
        isConfigured = function() return true end,
        jsonExtract = function(messages, opts, cb)
            Assert.eq(opts.max_tokens, 8000)
            prompts[#prompts + 1] = messages[2].content
            cb(table.remove(replies, 1))
        end,
    }
end

local full_reply = {
    known = true,
    characters = {
        { name = "Mina", aliases = { "Mina Harker" }, role = "heroine", description = "brave" },
        { name = "Van Helsing", aliases = {}, role = "doctor", description = "hunter" },
    },
    locations = { { name = "Whitby", description = "town" } },
    terms = { { name = "Dracula", aliases = {}, description = "title" } },
}

local Fetch = require("xray.fetch")
local identity = {
    source_id = "moon", stable_id = "book",
    book = { title = "Dracula", authors = "Stoker", intro = "A vampire novel." },
}

--- 重置库与 AI 队列后跑一次综合拉取。
local function run(rows, queued, ident, force)
    entity_rows, replies, prompts = rows, queued, {}
    local result, failure
    Fetch.comprehensive({}, ident or identity, { force = force ~= false }, function(value, err)
        result, failure = value, err
    end)
    return result, failure
end

-- 初始化：库空时凭通用知识生成，不要求名字出现在正文
local result, failure = run({}, { full_reply })
Assert.is_nil(failure)
Assert.len(prompts, 1)
Assert.matches(prompts[1], "凭你对这本书的已有知识")
Assert.matches(prompts[1], "A vampire novel%.")
Assert.eq(prompts[1]:find("阅读进度", 1, true), nil)
Assert.eq(#result.characters, 2)
Assert.eq(#result.locations, 1)
Assert.eq(#result.terms, 1)
Assert.len(entity_rows, 4)

-- 模型不认识这本书：回落到章节上下文，并做 grounding
result, failure = run({}, {
    { known = false },
    { characters = { { name = "Mina", aliases = {} }, { name = "Imaginary", aliases = {} } },
      locations = {}, terms = {} },
})
Assert.is_nil(failure)
Assert.len(prompts, 2)
Assert.matches(prompts[2], "CURRENT PAGE")
Assert.eq(#result.characters, 1)
Assert.eq(result.characters[1].name, "Mina")

-- 没有书名：直接走章节上下文
result, failure = run({}, { full_reply }, { source_id = "moon", stable_id = "x", book = {} })
Assert.is_nil(failure)
Assert.len(prompts, 1)
Assert.matches(prompts[1], "CURRENT PAGE")
Assert.matches(prompts[1], "阅读进度：约 42%%")
Assert.eq(#result.characters, 1)

-- 已有数据 + force：章节增量，合并旧实体并丢弃未 grounding 的名字
result, failure = run({
    { kind = "character", name = "Old", aliases = {}, role = "", description = "", updated_at = 1 },
}, {
    { characters = { { name = "Mina", aliases = {} }, { name = "Imaginary", aliases = {} } },
      locations = {}, terms = {} },
})
Assert.is_nil(failure)
Assert.len(prompts, 1)
Assert.matches(prompts[1], "EXISTING ENTITIES:\n人物：\n%- Old")
local names = {}
for index, row in ipairs(result.characters) do names[row.name] = true end
Assert.is_true(names.Old)
Assert.is_true(names.Mina)
Assert.is_nil(names.Imaginary)

-- 已有数据且非 force：直接回缓存，不请求 AI
result, failure = run({
    { kind = "character", name = "Old", aliases = {}, role = "", description = "", updated_at = 1 },
}, {}, nil, false)
Assert.is_nil(failure)
Assert.len(prompts, 0)
Assert.is_true(result.cached)

-- AI 失败：不回落，直接报错
result, failure = run({}, {})
Assert.is_nil(result)
Assert.len(prompts, 1)
