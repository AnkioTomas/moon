---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

--[[-- ai.summary_db：章节摘要参数化读写、防剧透查询边界、多文件书读书报告、身份迁移。 --]]

local Assert = require("support.assert")

local calls = {}
local rows = {}
local connection = {
    exec = function(_conn, sql)
        calls[#calls + 1] = { sql = sql, args = {} }
    end,
    close = function() end,
    prepare = function(_conn, sql)
        local call = { sql = sql }
        calls[#calls + 1] = call
        return {
            bind = function(self, ...)
                call.args = { ... }
                return self
            end,
            step = function()
                if sql:find("SELECT title, summary", 1, true) and rows.get then
                    return rows.get, { "title", "summary", "updated_at" }
                end
                if sql:find("SELECT extra", 1, true) and rows.extra then
                    return { rows.extra }, { "extra" }
                end
            end,
            resultset = function()
                local r = rows.list or {}
                local cols = { {}, {}, {}, {} }
                for i, row in ipairs(r) do
                    for c = 1, 4 do cols[c][i] = row[c] end
                end
                return cols, #r
            end,
            close = function() end,
        }
    end,
}

package.preload["utils.task"] = function()
    return { inSubProcess = function() return true end }
end
package.preload["utils.paths"] = function()
    return { dbPath = function() return "unused.sqlite3" end, ensureSettings = function() end }
end
package.preload["lua-ljsqlite3/init"] = function()
    return { open = function() return connection end }
end

local Base = require("utils.db")
local SummaryDB = require("ai.summary_db")
Base.open()

local created = false
for _idx, call in ipairs(calls) do
    if call.sql:find("CREATE TABLE IF NOT EXISTS chapter_summaries", 1, true) then created = true end
end
Assert.is_true(created, "打开连接时建表")

-- 写入：参数化，键为 (源, 书, 章)
Assert.is_true(SummaryDB.put("wechat", "b'1", 3, "第三章", "摘要"))
local put = calls[#calls]
Assert.matches(put.sql, "INSERT INTO chapter_summaries")
Assert.eq(put.args[1], "wechat")
Assert.eq(put.args[2], "b'1")
Assert.eq(put.args[3], 3)
Assert.eq(put.args[4], "第三章")
Assert.eq(put.args[5], "摘要")

-- 读单章：无行返回 nil
Assert.is_nil(SummaryDB.get("wechat", "b1", 9))
rows.get = { "第二章", "他走了", 100 }
local got = SummaryDB.get("wechat", "b1", 2)
Assert.eq(got.title, "第二章")
Assert.eq(got.summary, "他走了")
Assert.eq(got.updated_at, 100)

-- 截至某章：查询边界 1..max_idx（0 是全书总结，不混进前文），结果按章序升序
rows.list = { { 5, "五", "s5", 1 }, { 4, "四", "s4", 1 } }
local list = SummaryDB.upTo("wechat", "b1", 5, 2)
local q = calls[#calls]
Assert.matches(q.sql, "chapter_idx BETWEEN 1 AND %?")
Assert.eq(q.args[3], 5)
Assert.eq(q.args[4], 2)
Assert.len(list, 2)
Assert.eq(list[1].chapter_idx, 4)
Assert.eq(list[2].chapter_idx, 5)
rows.list = nil
Assert.len(SummaryDB.upTo("wechat", "b1", 1, 3), 0)

-- 身份：改名迁移、撕墓碑删除
Assert.is_true(SummaryDB.moveIdentity("local", "old", "new", false))
Assert.matches(calls[#calls].sql, "UPDATE chapter_summaries SET stable_id")
Assert.is_true(SummaryDB.removeIdentity("local", "new"))
Assert.matches(calls[#calls].sql, "DELETE FROM chapter_summaries")

-- 读书报告：整本书一行（chapter_idx=0），只写 extra 列，不动章节摘要列
Assert.is_nil(SummaryDB.report("wechat", "b1"))
rows.extra = ""
Assert.is_nil(SummaryDB.report("wechat", "b1"), "空串视为没有报告")
Assert.is_true(SummaryDB.putReport("wechat", "b1", "报告正文"))
local report = calls[#calls]
Assert.matches(report.sql, "INSERT INTO chapter_summaries %(source_id, stable_id, chapter_idx, extra, updated_at%)")
Assert.matches(report.sql, "DO UPDATE SET%s+extra=excluded.extra")
Assert.eq(report.args[3], 0)
Assert.eq(report.args[4], "报告正文")
rows.extra = "报告正文"
Assert.eq(SummaryDB.report("wechat", "b1"), "报告正文")
Assert.eq(calls[#calls].args[3], 0)

return true
