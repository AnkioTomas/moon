---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

--[[-- features.ai.summary：顺读进下一章才入队、跳读不入队、已有摘要不重复、按章文件取正文、任务写库。 --]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(value) return value end end
package.preload["ffi/util"] = function()
    return { template = function(fmt, a) return (fmt:gsub("%%1", tostring(a))) end }
end

local cfg = { ai_chapter_summary = true }
package.preload["utils.settings"] = function()
    return { get = function(owner)
        assert(owner == "ai")
        return cfg
    end }
end

local configured = true
local chats = {}
package.preload["ai"] = function()
    return {
        isConfigured = function() return configured end,
        chat = function(messages, opts, cb)
            chats[#chats + 1] = { messages = messages, opts = opts, cb = cb }
            return { cancel = function() end }
        end,
    }
end

local stored, puts = {}, {}
package.preload["ai.summary_db"] = function()
    return {
        get = function(source_id, stable_id, idx) return stored[source_id .. stable_id .. idx] end,
        put = function(source_id, stable_id, idx, title, summary)
            puts[#puts + 1] = { source_id = source_id, stable_id = stable_id, idx = idx, title = title, summary = summary }
            return true
        end,
    }
end

local queued = {}
package.preload["workers.tasks"] = function()
    return { enqueue = function(spec)
        queued[#queued + 1] = spec
        return spec
    end }
end

local ranges = {}
local chapter_body = string.rep("他走进了城门。", 40)
package.preload["reader.context"] = function()
    return { pagesText = function(ui, from, to)
        ranges[#ranges + 1] = { ui = ui, from = from, to = to }
        return chapter_body
    end }
end

local tmp_dir = os.tmpname()
os.remove(tmp_dir)
os.execute("mkdir -p '" .. tmp_dir .. "'")
package.preload["utils.paths"] = function()
    return { chapterPath = function(stable_id, idx, source_id)
        return tmp_dir .. "/" .. source_id .. "-" .. stable_id .. "-" .. idx .. ".html"
    end }
end

local session
local toc = {
    { idx = 1, title = "第一章", page = 1 },
    { idx = 2, title = "第二章", page = 10 },
    { idx = 3, title = "第三章", page = 20 },
    { idx = 4, title = "第四章", page = 30 },
    { idx = 5, title = "第五章", page = 40 },
}
local current_idx
package.preload["reader.session"] = function()
    return {
        current = function() return session end,
        chapterIndex = function() return current_idx end,
        toc = function() return toc end,
    }
end

local Summary = require("features.ai.summary")
local ui = {}

local book = { source_id = "local", stable_id = "/a.epub", book = { title = "边城" } }
---@param idx integer
---@param page integer
---@param identity table|nil
local function turn(idx, page, identity)
    current_idx = idx
    session = { identity = identity or book, page = page }
    Summary.onPage(ui)
end

-- 没有会话 / 不在任何章：什么都不做
session, current_idx = nil, nil
Summary.onPage(ui)
Assert.len(queued, 0)

-- 首次看到、章内翻页：不入队
turn(1, 8)
turn(1, 9)
Assert.len(queued, 0)

-- 顺着翻进第二章：给第一章入队，正文取两章起始页之间
turn(2, 10)
Assert.len(queued, 1)
local task = queued[1]
Assert.eq(task.kind, "cache")
Assert.is_true(task.restartable)
Assert.eq(task.key, "ai_summary\0local\0/a.epub\0" .. "1")
Assert.eq(task.title, "章节摘要：第一章")
Assert.eq(ranges[1].ui, ui)
Assert.eq(ranges[1].from, 1)
Assert.eq(ranges[1].to, 10)

-- 跑任务：提示词带书名、章名、正文；回答清洗后写库
task.run(function() end, function(result) task.result = result end)
Assert.len(chats, 1)
local prompt = chats[1].messages[2].content
Assert.matches(prompt, "《边城》")
Assert.matches(prompt, "章节：第一章")
Assert.matches(prompt, "他走进了城门")
Assert.matches(chats[1].messages[1].content, "不透露后文")
chats[1].cb("**翠翠**在渡口等人。")
Assert.is_true(task.result.ok)
Assert.eq(puts[1].idx, 1)
Assert.eq(puts[1].title, "第一章")
Assert.eq(puts[1].summary, "翠翠在渡口等人。")

-- 失败（含离线）：done 报失败，交给队列决定等网络还是放弃，不写库
local before_puts = #puts
task.run(function() end, function(result) task.result = result end)
chats[#chats].cb(nil, "timeout")
Assert.is_false(task.result.ok)
Assert.eq(task.result.err, "timeout")
Assert.eq(#puts, before_puts)

-- 已有摘要：不重复入队
stored["local/a.epub2"] = { summary = "已有" }
local before_ranges = #ranges
turn(2, 19)
turn(3, 20)
Assert.len(queued, 1)
Assert.eq(#ranges, before_ranges, "已有摘要时连正文都不取")

-- 目录跳转（页码跳太远）、往回翻：不入队
turn(5, 40)
turn(4, 30)
Assert.len(queued, 1)

-- 开关关 / AI 未配置：不入队
turn(4, 35)
cfg.ai_chapter_summary = false
turn(5, 36)
Assert.len(queued, 1)
cfg.ai_chapter_summary = true
configured = false
turn(4, 30)
turn(5, 31)
Assert.len(queued, 1)
configured = true

-- 太短的章（扉页、分卷名）不值得概括
chapter_body = "卷一"
turn(4, 30)
turn(5, 31)
Assert.len(queued, 1)
chapter_body = string.rep("他走进了城门。", 40)

-- 换了一本书：上一本记住的位置不算
local other = { source_id = "local", stable_id = "/b.epub", book = { title = "乙" } }
turn(1, 1, other)
Assert.len(queued, 1)

-- 按章打开：章序号 +1 才算顺读，正文读刚读完那章的章节文件
local chaptered = { source_id = "wechat", stable_id = "w1", chapter_idx = 3, book = { title = "三体" } }
local f = assert(io.open(tmp_dir .. "/wechat-w1-3.html", "wb"))
f:write("<html><body><p>" .. string.rep("叶文洁按下了按钮。", 30) .. "</p></body></html>")
f:close()
turn(3, 12, chaptered)
chaptered = { source_id = "wechat", stable_id = "w1", chapter_idx = 4, book = { title = "三体" } }
turn(4, 1, chaptered)
Assert.len(queued, 2)
Assert.eq(queued[2].key, "ai_summary\0wechat\0w1\0" .. "3")
queued[2].run(function() end, function() end)
local chapter_prompt = chats[#chats].messages[2].content
Assert.matches(chapter_prompt, "叶文洁按下了按钮")
Assert.is_nil(chapter_prompt:find("<p>", 1, true), "章节 HTML 剥成纯文本")

-- 按章打开跳了章：不入队
turn(6, 1, { source_id = "wechat", stable_id = "w1", chapter_idx = 6, book = {} })
Assert.len(queued, 2)

-- 超长正文：保留开头与结尾，中间省略
local long = string.rep("甲", 4000) .. string.rep("乙", 4000)
local messages = Summary.messages("书", "章", long)
local body = messages[2].content
Assert.matches(body, "……")
Assert.matches(body, "甲甲甲")
Assert.matches(body, "乙乙乙")
Assert.is_true(#body < #long, "超长正文被截短")

os.execute("rm -rf '" .. tmp_dir .. "'")
return true
