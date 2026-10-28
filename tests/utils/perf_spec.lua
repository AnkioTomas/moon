--[[-- 性能计时使用毫秒墙钟并输出非负耗时。 --]]

local Assert = require("support.assert")

local values = { 1, 1.0025 }
package.preload["socket"] = function()
    return {
        gettime = function() return table.remove(values, 1) end,
    }
end
package.loaded["socket"] = nil
package.loaded["utils.perf"] = nil

local Perf = require("utils.perf")
local started_at = Perf.now()
Assert.eq(Perf.elapsedMs(started_at), 3)

-- 分段计时：每步记自上一步起的毫秒，finish 按总耗时选 warn / dbg，extra 原样带上，一行落盘。
values = { 10, 10.012, 10.350, 10.360 }
local lines = {}
package.loaded["utils.log"] = { warn = function(...) lines[#lines + 1] = { "warn", ... } end,
    dbg = function(...) lines[#lines + 1] = { "dbg", ... } end }
local span = Perf.begin("reader.ready")
span:lap("identity")
span:lap("snapshot")
Assert.eq(span:finish(300, "wechat", "chapter"), 360)
Assert.eq(lines[1][1], "warn", "总耗时 ≥ 阈值按 warn")
Assert.eq(lines[1][2], "book.perf reader.ready")
Assert.eq(lines[1][3], 360)
Assert.eq(lines[1][5], "wechat"); Assert.eq(lines[1][6], "chapter")
Assert.eq(lines[1][7], "identity=12 snapshot=338")
values = { 20, 20.001 }
Perf.begin("quick"):finish(300)
Assert.eq(lines[2][1], "dbg", "没超阈值只记 dbg")
Assert.eq(lines[2][5], "", "没有 lap 时分段串为空")
package.loaded["utils.log"] = nil
