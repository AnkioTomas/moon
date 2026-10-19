--[[-- features.xray.fetch：mock AI.jsonExtract，校验初始化/增量两条路径与合并落库。 --]]

local Assert = require("support.assert")
local Json = require("support.json_stub")

package.preload["json"] = function()
    return { decode = Json.decode, encode = Json.encode }
end

local entity_rows = {}
local scan_cursor
package.preload["features.xray.db"] = function()
    return {
        scanCursor = function() return scan_cursor end,
        saveScanCursor = function(source_id, stable_id, digest, done, total)
            scan_cursor = { digest = digest, done = done, total = total }
            return true
        end,
        clearScanCursor = function() scan_cursor = nil; return true end,
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
local prior_limits = {}
package.preload["reader.context"] = function()
    return {
        forAnalysis = function(ui, prior_limit)
            prior_limits[#prior_limits + 1] = prior_limit or "default"
            return {
                current_page = "Mina at Whitby saw Dracula",
                prior_text = "prior",
                page = 5,
            }
        end,
        currentPage = function() return 5 end,
    }
end
local chapter_idx
package.preload["reader.session"] = function()
    return {
        current = function() return { percent = 42 } end,
        chapterIndex = function() return chapter_idx end,
    }
end

--- 每次调用按顺序吐一个预设响应，并记下 prompt。
local replies, prompts = {}, {}
local recap, recap_asked
package.preload["ai"] = function()
    return {
        isConfigured = function() return true end,
        priorSummaries = function(ident, idx, chapters)
            recap_asked = { identity = ident, idx = idx, chapters = chapters }
            return recap
        end,
        jsonExtract = function(messages, opts, cb)
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

local Fetch = require("features.xray.fetch")
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
prior_limits = {}
result, failure = run({
    { kind = "character", name = "Old", aliases = {}, role = "", description = "老管家", updated_at = 1 },
}, {
    { characters = { { name = "Mina", aliases = {} }, { name = "Imaginary", aliases = {} } },
      locations = {}, terms = {} },
})
Assert.is_nil(failure)
Assert.len(prompts, 1)
Assert.matches(prompts[1], "EXISTING ENTITIES:\n人物：\n%- Old — 老管家")
Assert.matches(prompts[1], "把正文中的写法原样加入 aliases")
Assert.matches(prompts[1], "以 EXISTING 中的原描述为基础")
Assert.eq(prior_limits[1], "default", "刷新用章节全量前文")
local names = {}
for index, row in ipairs(result.characters) do names[row.name] = true end
Assert.is_true(names.Old)
Assert.is_true(names.Mina)
Assert.is_nil(names.Imaginary)

-- 没有前文摘要：提示词不带 STORY SO FAR（与原来一致）
Assert.is_nil(prompts[1]:find("STORY SO FAR", 1, true))

-- 有前文摘要：增量与划词提示词末尾带上，按当前章取最多 5 章
chapter_idx, recap = 7, "第六章\n伯爵来到了惠特比。"
run({ { kind = "character", name = "Old", aliases = {}, role = "", description = "", updated_at = 1 } }, {
    { characters = {}, locations = {}, terms = {} },
})
Assert.matches(prompts[1], "STORY SO FAR")
Assert.matches(prompts[1], "伯爵来到了惠特比。$")
Assert.eq(recap_asked.identity, identity)
Assert.eq(recap_asked.idx, 7)
Assert.eq(recap_asked.chapters, 5)
entity_rows, prompts = {}, {}
replies = { { is_valid = true, type = "character", item = { name = "Mina", aliases = {}, description = "x" } } }
Fetch.lookupWord({}, identity, "Mina", function() end)
Assert.matches(prompts[1], "伯爵来到了惠特比。$")
chapter_idx, recap = nil, nil

-- 已有数据且非 force：直接回缓存，不请求 AI
result, failure = run({
    { kind = "character", name = "Old", aliases = {}, role = "", description = "", updated_at = 1 },
}, {}, nil, false)
Assert.is_nil(failure)
Assert.len(prompts, 0)
Assert.is_true(result.cached)

-- 划词：只取小段前文
entity_rows, prompts, prior_limits = {}, {}, {}
replies = { { is_valid = true, type = "character", item = { name = "Mina", aliases = {}, description = "x" } } }
local looked
Fetch.lookupWord({}, identity, "Mina", function(item) looked = item end)
Assert.eq(looked.name, "Mina")
Assert.eq(prior_limits[1], 2000)
Assert.matches(prompts[1], "全书中的整体描述")

-- 只查本地：名字、别名都认，不分大小写；没收录返回 nil，不请求 AI
entity_rows, prompts = {
    { kind = "character", name = "Mina", aliases = { "Mina Harker" } },
}, {}
Assert.eq(Fetch.findLocal(identity, " mina harker ").name, "Mina")
Assert.eq(Fetch.findLocal(identity, "MINA").name, "Mina")
Assert.is_nil(Fetch.findLocal(identity, "Lucy"))
Assert.len(prompts, 0)

-- AI 失败：不回落，直接报错
result, failure = run({}, {})
Assert.is_nil(result)
Assert.len(prompts, 1)

-- 分段：优先在换行处断开；没有合适换行时不切断 UTF-8 字符
local parts = Fetch.chunks("aaaa\nbbbb\ncc", 6)
Assert.eq(parts[1], "aaaa")
Assert.eq(parts[2], "bbbb")
Assert.eq(parts[3], "cc")
parts = Fetch.chunks("一二三四", 7)
Assert.eq(parts[1], "一二")
Assert.eq(parts[2], "三四")
Assert.len(Fetch.chunks("", 8), 0)
Assert.len(Fetch.chunks("  \n  ", 8), 0)

-- 全书分析：逐段请求、每段落库；只带本段提到的已收录实体；失败后重跑从断点续
local invalidated = 0
package.loaded["features.xray.marks"] = { invalidate = function() invalidated = invalidated + 1 end }
local chunk_a = string.rep("x", 20000) .. " Mina at Whitby"
local chunk_b = string.rep("y", 20000) .. " Lucy met Mina"
entity_rows, prompts = {
    { kind = "character", name = "Old", aliases = {}, role = "", description = "老管家", updated_at = 1 },
}, {}
replies = {
    { characters = { { name = "Mina", aliases = {} }, { name = "Ghost", aliases = {} } }, locations = {}, terms = {} },
}
local scan = Fetch.scanBook(identity, chunk_a .. "\n" .. chunk_b)
local reports = {}
---@type { ok: boolean, err: any, progressed: boolean|nil }
local outcome
local function attempt()
    outcome = nil
    scan(function(text, count, total) reports[#reports + 1] = { text, count, total } end,
        function(res) outcome = res end)
end
attempt()
Assert.eq(outcome.ok, false, "第二段没回复，本次尝试失败")
Assert.is_true(outcome.progressed, "做完了一段：这次失败不计入重试次数")
Assert.eq(invalidated, 1, "页内标记只在尝试结束时刷新一次")
Assert.eq(scan_cursor.done, 1, "游标落库：第一段已完成")
Assert.eq(scan_cursor.total, 2)
Assert.eq(Fetch.scanProgress(identity).done, 1)
Assert.len(prompts, 2)
Assert.is_nil(prompts[1]:find("Old", 1, true), "本段没提到的实体不进提示词")
Assert.matches(prompts[2], "%- Mina")
Assert.eq(reports[1][2], 0)
Assert.eq(reports[1][3], 2)
local names_after = {}
for _idx, row in ipairs(entity_rows) do names_after[row.name] = true end
Assert.is_true(names_after.Old)
Assert.is_true(names_after.Mina)
Assert.is_nil(names_after.Ghost, "未在本段出现的名字丢弃")

-- 没推进的失败照常计入重试次数
prompts = {}
attempt()
Assert.eq(outcome.ok, false)
Assert.is_true(not outcome.progressed)

-- 下次重新点「分析全书」：新建的任务体按游标从第二段开始
prompts = {}
scan = Fetch.scanBook(identity, chunk_a .. "\n" .. chunk_b)
-- 输出被截断时后面的段缺失（nil），只处理有的部分
replies = { { characters = { { name = "Lucy", aliases = {} } } } }
attempt()
Assert.eq(outcome.ok, true)
Assert.is_nil(scan_cursor, "全部完成删游标")
Assert.is_nil(Fetch.scanProgress(identity))
Assert.len(prompts, 1, "重跑只请求没做完的段")
Assert.matches(prompts[1], "Lucy met Mina")
Assert.eq(reports[#reports][2], 2)
names_after = {}
for _idx, row in ipairs(entity_rows) do names_after[row.name] = true end
Assert.is_true(names_after.Lucy)
