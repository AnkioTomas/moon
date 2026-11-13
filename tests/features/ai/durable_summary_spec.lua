--[[--
真实 SQLite + 真实任务队列：摘要重启恢复、暂停与取消、失败重试、队列补位、身份和清理边界。

@module tests.features.ai.durable_summary_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")
local Stubs = require("support.stubs")
local Themed = require("support.theme_stubs")
Themed.install()
local path = require("support.config").dir() .. "/durable-summary-spec.sqlite3"
for _idx, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(path .. suffix) end
package.preload["utils.paths"] = function() return { dbPath = function() return path end } end
package.preload["utils.log"] = function()
    return { info = function() end, warn = function() end, dbg = function() end }
end
package.preload["utils.awake"] = function() return { hold = function() end } end
local JSON = require("support.json_stub")
package.preload["json"] = function() return JSON end
local cfg, configured, connected = { ai_chapter_summary = true }, true, true
package.preload["utils.settings"] = function() return { get = function() return cfg end } end
package.preload["ui/network/manager"] = function() return { isConnected = function() return connected end } end
local requests = {}
package.preload["ai"] = function()
    return {
        isConfigured = function() return configured end,
        chat = function(messages, _opts, cb)
            local request = { messages = messages, cb = cb }
            requests[#requests + 1] = request
            return { cancel = function() request.cancelled = true end }
        end,
    }
end
package.preload["dispatcher"] = function() return { registerAction = function() end } end
package.preload["ui.guard"] = function()
    return { call = function(_label, fn, ...) return fn(...) end }
end
local session
package.preload["reader.session"] = function() return { current = function() return session end } end

local DB = require("utils.db")
local SummaryDB = require("ai.summary_db")
local Summary = require("features.ai.summary")
local Ai = require("features.ai")
local Tasks = require("workers.tasks")
local function key(stable_id, idx)
    return "ai_summary\0local\0" .. stable_id .. "\0" .. idx
end
local function save(stable_id, idx)
    local messages = JSON.encode(Summary.messages("书名", "章节", string.rep("正文", 4000)))
    Assert.is_true(SummaryDB.putPending("local", stable_id, idx, "章节", messages))
    return messages
end

local snapshot = save("restart", 1)
Assert.is_nil(SummaryDB.get("local", "restart", 1), "待办不是空摘要")
Assert.is_true(#snapshot < 13000, "正文快照保留裁剪边界")
local plugin = {}
Ai.onCreate(plugin)
Assert.len(requests, 1)
Assert.eq(requests[1].messages[2].content, JSON.decode(snapshot)[2].content)
local old_request = requests[1]
Ai.onExit(plugin)
Tasks.onSuspend()
Assert.is_true(old_request.cancelled)
Assert.not_nil(SummaryDB.getPending("local", "restart", 1))
DB.close()
package.loaded["workers.tasks"] = nil
Tasks = require("workers.tasks")
Ai.onCreate(plugin)
Stubs.flush()
Assert.len(requests, 2, "新队列和重开的数据库从快照恢复，无需阅读文档")
old_request.cb("迟到的旧结果")
Assert.is_nil(SummaryDB.get("local", "restart", 1))
requests[2].cb("**恢复后的摘要**")
Stubs.flush()
Assert.eq(SummaryDB.get("local", "restart", 1).summary, "恢复后的摘要")
Assert.is_nil(SummaryDB.getPending("local", "restart", 1))

save("pause", 1)
Summary.resume()
local before_pause = requests[#requests]
Tasks.onSuspend()
Assert.not_nil(SummaryDB.getPending("local", "pause", 1))
Tasks.onResume()
before_pause.cb("暂停之前的结果")
Assert.is_nil(SummaryDB.get("local", "pause", 1))
local live_task = Tasks.get(key("pause", 1))
live_task.cancel()
requests[#requests].cb("取消之后的结果")
Stubs.flush()
Assert.is_nil(SummaryDB.getPending("local", "pause", 1))
Assert.is_nil(SummaryDB.get("local", "pause", 1))

save("retry", 1)
Summary.resume()
requests[#requests].cb(nil, "quota exceeded")
Stubs.flush()
Assert.eq(SummaryDB.getPending("local", "retry", 1).error, "quota exceeded")
Assert.matches(Themed.last("toast").text, "quota exceeded")
local failed_count = #requests
Ai.onExit(plugin)
Ai.onCreate(plugin)
Stubs.flush()
Assert.len(requests, failed_count, "失败快照不能在启动时不断重发")
cfg.ai_chapter_summary = false
session = { identity = { source_id = "local", stable_id = "retry" } }
require("features.ai.panel").actions()[1].hold()
Assert.len(requests, failed_count + 1, "手动重试不要求开启自动摘要")
requests[#requests].cb("手动重试成功")
Stubs.flush()
Assert.is_nil(SummaryDB.getPending("local", "retry", 1))
cfg.ai_chapter_summary = true

save("offline", 1)
Summary.resume()
connected = false
local toast_count = #Themed.all("toast")
requests[#requests].cb(nil, "offline")
Stubs.flush()
Assert.eq(Tasks.get(key("offline", 1)).state, "waiting")
Assert.eq(SummaryDB.getPending("local", "offline", 1).error, "")
Assert.len(Themed.all("toast"), toast_count, "断网等待不提示永久失败")
connected = true
Tasks.onNetworkConnected()
requests[#requests].cb("联网完成")
Stubs.flush()
Assert.is_nil(SummaryDB.getPending("local", "offline", 1))

save("atomic", 1)
local remove = SummaryDB.removePending
SummaryDB.removePending = function() return false end
Assert.is_false(SummaryDB.finishPending("local", "atomic", 1, "章节", "不能半提交"))
SummaryDB.removePending = remove
Assert.is_nil(SummaryDB.get("local", "atomic", 1))
Assert.not_nil(SummaryDB.getPending("local", "atomic", 1), "删除待办失败时摘要写入一起回滚")
Assert.is_true(SummaryDB.removePending("local", "atomic", 1))

for idx = 1, 64 do
    Assert.not_nil(Tasks.enqueue{
        key = "blocker\0" .. idx, kind = "sync",
        run = function() return { cancel = function() end } end,
    })
end
save("full", 1)
local count, err = Summary.resume()
Assert.eq(count, 0)
Assert.eq(err, "queue_full")
Assert.not_nil(SummaryDB.getPending("local", "full", 1))
Tasks.get("blocker\0" .. 1).cancel()
Stubs.flush()
Assert.eq(Tasks.get(key("full", 1)).state, "queued", "有空位就补入，但不抢占同步任务")
Tasks.cancelPrefixed("blocker")
requests[#requests].cb("队列空位恢复")
Stubs.flush()
Assert.is_nil(SummaryDB.getPending("local", "full", 1))

local Events = require("features.ai.events")
save("rename-me", 1)
Summary.resume()
local old_identity_request = requests[#requests]
Assert.is_true(DB.transaction(function()
    return SummaryDB.moveIdentity("local", "rename-me", "renamed")
        and Events.book_identity_changed("local", "rename-me", "renamed")
end))
Stubs.flush()
Assert.is_nil(SummaryDB.getPending("local", "rename-me", 1))
Assert.not_nil(Tasks.get(key("renamed", 1)))
old_identity_request.cb("旧身份的结果")
Assert.is_nil(SummaryDB.get("local", "rename-me", 1))
requests[#requests].cb("新身份的结果")
Stubs.flush()
Assert.eq(SummaryDB.get("local", "renamed", 1).summary, "新身份的结果")

save("delete-me", 1)
Summary.resume()
local deleted_request = requests[#requests]
Assert.is_true(DB.transaction(function()
    return SummaryDB.removeIdentity("local", "delete-me") and Events.book_removed("local", "delete-me")
end))
deleted_request.cb("删除后不应复活")
Stubs.flush()
Assert.is_nil(SummaryDB.get("local", "delete-me", 1))
Assert.is_nil(Tasks.get(key("delete-me", 1)))

save("scope/remove", 1)
save("scope/keep", 1)
Summary.resume()
Assert.is_true(DB.transaction(function()
    return SummaryDB.removeSource("local", "scope/remove") and Events.source_reading_cleared("local")
end))
Stubs.flush()
Assert.is_nil(Tasks.get(key("scope/remove", 1)))
Assert.not_nil(Tasks.get(key("scope/keep", 1)))
Assert.not_nil(SummaryDB.getPending("local", "scope/keep", 1), "范围外的待办和请求必须保留")
save("outside", 1)
Summary.resume()
Assert.is_true(DB.transaction(function()
    return SummaryDB.removeSource("local", "scope/keep", true) and Events.source_reading_cleared("local")
end))
Stubs.flush()
Assert.is_nil(Tasks.get(key("outside", 1)))
Assert.not_nil(Tasks.get(key("scope/keep", 1)), "反选清理不能撤销被排除前缀的待办")
Assert.is_true(DB.transaction(function()
    return SummaryDB.removeSource("local") and Events.source_forgotten("local")
end))
Stubs.flush()
Assert.len(Tasks.tasks(), 0)
Assert.len(SummaryDB.pending(), 0)

cfg.ai_chapter_summary = false
save("disabled", 1)
local before_disabled = #requests
Assert.eq(Summary.resume(), 0)
Assert.len(requests, before_disabled)
cfg.ai_chapter_summary, configured = true, false
Assert.eq(Summary.resume(), 0)
Assert.len(requests, before_disabled)
configured = true
Summary.resume()
requests[#requests].cb("启用后恢复")
Stubs.flush()
Assert.is_nil(SummaryDB.getPending("local", "disabled", 1))

for idx, malformed in ipairs({ "not json", "{}", '[{"role":"user"}]' }) do
    Assert.is_true(SummaryDB.putPending("local", "damaged", idx, "章节", malformed))
    local before = #requests
    local _count, damaged_err = Summary.resume()
    Assert.matches(damaged_err, "内容损坏")
    Assert.len(requests, before, "损坏的快照不能发起 AI 请求")
    Assert.is_true(SummaryDB.getPending("local", "damaged", idx).error ~= "")
end
local damaged = SummaryDB.getPending("local", "damaged", 1)
Assert.is_true(SummaryDB.putPending("local", "damaged", 1, "覆盖", "[]"))
Assert.eq(SummaryDB.getPending("local", "damaged", 1).messages, damaged.messages)
Assert.eq(SummaryDB.getPending("local", "damaged", 1).error, damaged.error, "重读不覆盖快照或重置失败状态")
Assert.is_true(SummaryDB.removeIdentity("local", "damaged"))

Ai.onExit(plugin)
DB.close()
for _idx, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(path .. suffix) end
return true
