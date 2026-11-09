--[[--
大目录分批冷读、文件交接、取消和快照变更；子进程不允许碰业务库。

@module tests.source.toc_async_spec
--]]
---@diagnostic disable: undefined-field, missing-fields
local Assert = require("support.assert")
local Config = require("support.config")
local path = Config.dir() .. "/toc_async_spec.sqlite3"
for _idx, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(path .. suffix) end
local transfer, transfers = nil, 0
package.preload["utils.paths"] = function()
    return {
        dbPath = function() return path end,
        sanitizeSourceId = function(id) return id end,
        tmpname = function()
            transfers = transfers + 1
            transfer = Config.dir() .. "/toc-transfer-" .. transfers
            return transfer
        end,
    }
end
local UI = require("ui/uimanager")
local queue, in_child = {}, false
function UI:nextTick(fn) queue[#queue + 1] = fn end
function UI:scheduleIn(_delay, fn) queue[#queue + 1] = fn end
function UI:unschedule(fn)
    for i = #queue, 1, -1 do if queue[i] == fn then table.remove(queue, i) end end
end
local function tick()
    Assert.is_true(#queue > 0)
    table.remove(queue, 1)()
end
package.loaded["workers.job"] = {
    inSubProcess = function() return in_child end,
    run = function(worker, opts)
        local job = {}
        function job:cancel() self.cancelled = true end
        UI:nextTick(function()
            if job.cancelled then return end
            in_child = true
            local ok, result = pcall(worker)
            in_child = false
            if ok then
                Assert.is_nil(result[1], "目录不能作为巨大 JSON 结果帧回传")
                opts.on_done(result)
            else opts.on_failed(result) end
        end)
        return job
    end,
}
local DB = require("utils.db")
local BookDB = require("book.books_db")
local TocDB = require("book.toc_db")
local Toc = require("source.toc")
local list = {}
for i = 1, 40 do list[i] = { idx = i, uid = "u" .. i, title = "章节" .. i, origin = "/" .. i } end
Assert.is_true(Toc.put("18ta", "native", list))
Toc.clear()
local result, reason, calls = nil, nil, 0
local function done(value, err) result, reason, calls = value, err, calls + 1 end
local operation = Toc.readAsync("18ta", "native", done)
tick()
Assert.is_nil(result, "第一批读取不得直接同步载入整本")
Assert.eq(calls, 0)
operation.cancel()
Assert.len(queue, 0)
Assert.eq(calls, 0, "取消不交付半目录")
Toc.readAsync("18ta", "native", done)
while #queue > 0 do tick() end
Assert.len(result, 40)
Assert.eq(result[40].origin, "/40")
Assert.eq(calls, 1)
Toc.clear()
calls, result = 0, nil
Toc.readAsync("18ta", "native", done)
tick()
local _at, revision = TocDB.snapshot("18ta", "native")
Assert.is_true(TocDB.put("18ta", "native", { { idx = 1, uid = "new", title = "新目录" } }, _at))
local _same_at, updated = TocDB.snapshot("18ta", "native")
Assert.eq(updated, revision + 1, "同一秒刷新也必须识别快照变更")
tick()
Assert.is_nil(result)
Assert.eq(reason, "toc snapshot changed")
Assert.eq(calls, 1)

Assert.is_true(BookDB.setToc("18ta", "legacy", require("dkjson").encode(list)))
Toc.readAsync("18ta", "legacy", done)
tick()
Assert.not_nil(BookDB.getToc("18ta", "legacy"))
tick()
Assert.is_nil(TocDB.read("18ta", "legacy"), "解析完但接收未结束时不能发布半目录")
while #queue > 0 do tick() end
Assert.len(result, 40)
Assert.is_nil(BookDB.getToc("18ta", "legacy"))
Assert.eq(result[40].uid, "u40")
Assert.is_nil(io.open(transfer, "rb"), "交接文件用完即删")
Assert.is_true(TocDB.update("18ta", "legacy", 1, "words", 1234))
operation = Toc.parseAsync("18ta", "legacy", function() return list end, done)
tick()
operation.cancel()
Assert.len(queue, 0)
Assert.is_nil(io.open(transfer, "rb"))
Assert.eq(TocDB.read("18ta", "legacy")[1].words, 1234, "取消保留旧快照")
Toc.parseAsync("18ta", "legacy", function() return nil, "bad html" end, done)
while #queue > 0 do tick() end
Assert.is_nil(result)
Assert.eq(reason, "bad html")
Assert.eq(TocDB.read("18ta", "legacy")[1].words, 1234)
Toc.parseAsync("18ta", "legacy", function()
    return { { idx = 1, uid = "duplicate", title = "重复" }, { idx = 1, title = "重复" } }
end, done)
while #queue > 0 do tick() end
Assert.is_nil(result)
Assert.eq(reason, "章节目录保存失败")
Assert.eq(TocDB.read("18ta", "legacy")[1].words, 1234)
Assert.is_nil(io.open(transfer, "rb"))
Toc.parseAsync("18ta", "legacy", function() return list end, done)
tick()
Assert.is_true(TocDB.put("18ta", "legacy", { { idx = 1, uid = "latest", title = "最新目录" } }))
while #queue > 0 do tick() end
Assert.is_nil(result)
Assert.eq(reason, "toc snapshot changed", "较早的解析结果不能盖掉较新的目录")
Assert.eq(TocDB.read("18ta", "legacy")[1].uid, "latest")
Assert.is_nil(io.open(transfer, "rb"))
Assert.is_true(DB.exec("UPDATE toc_entries SET extra=? WHERE source_id=? AND stable_id=?;", "7", "18ta", "legacy"))
Toc.clear()
Toc.readAsync("18ta", "legacy", done)
while #queue > 0 do tick() end
Assert.is_nil(result)
Assert.eq(reason, "toc read failed", "坏扩展字段须回调失败，不能让开书进度窗一直等")
DB.close()
for _idx, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(path .. suffix) end
