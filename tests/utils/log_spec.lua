--[[--
插件独立日志：级别、调试开关与重启清理。

@module tests.utils.log_spec
--]]

local Assert = require("support.assert")
local Config = require("support.config")
local Stubs = require("support.stubs")

if not Config.available() then
    Assert.skip("沙箱数据目录未就绪，请用 ./tests/run.sh 运行")
end

local Settings = Config.settings()
local original_debug = Settings.get("common").book_debug_enabled
Settings.save({ book_debug_enabled = false })

package.preload["utils.log"] = nil
package.loaded["utils.log"] = nil
local Log = require("utils.log")
os.remove(Log.path())
Log.start()
Log.info("hello", 7)
Log.dbg("hidden")
Log.warn("careful")
Log.error("broken")

local file = assert(io.open(Log.path(), "r"))
local content = file:read("*a")
file:close()
Assert.is_nil(content:find("[INFO] hello 7", 1, true))
Assert.is_nil(content:find("[WARN] careful", 1, true))
Assert.is_nil(content:find("hidden", 1, true))

for i = 3, 9 do Log.warn("batch", i) end
Stubs.flush()
file = assert(io.open(Log.path(), "r"))
content = file:read("*a")
file:close()
Assert.eq(content, "")

Log.warn("batch", 10)
Log.warn("tail", 11)
Log.flush()
file = assert(io.open(Log.path(), "r"))
content = file:read("*a")
file:close()
Assert.eq(content, "")
Stubs.flush()
file = assert(io.open(Log.path(), "r"))
content = file:read("*a")
file:close()
Assert.not_nil(content:find("[WARN] careful", 1, true))
Assert.not_nil(content:find("[ERROR] broken", 1, true))
Assert.not_nil(content:find("[WARN] batch 10", 1, true))
Assert.not_nil(content:find("[WARN] tail 11", 1, true))

Settings.save({ book_debug_enabled = true })
Log.dbg("visible")
Log.info("hello", 7)
Log.flush()
Stubs.flush()
file = assert(io.open(Log.path(), "r"))
content = file:read("*a")
file:close()
Assert.not_nil(content:find("[DEBUG] visible", 1, true))
Assert.not_nil(content:find("[INFO] hello 7", 1, true))
Assert.not_nil(content:find("[WARN] tail 11", 1, true))

-- 同一天重启继续追加，崩溃后的下一次启动不能先把诊断证据删掉。
package.loaded["utils.log"] = nil
local RestartedLog = require("utils.log")
RestartedLog.info("fresh")
RestartedLog.flush()
Stubs.flush()
file = assert(io.open(RestartedLog.path(), "r"))
content = file:read("*a")
file:close()
Assert.not_nil(content:find("[INFO] fresh", 1, true))
Assert.not_nil(content:find("visible", 1, true))

-- 跨天首次启动才清空旧日志，避免日志无限增长。
local lfs = require("libs/libkoreader-lfs")
Assert.is_true(lfs.touch(RestartedLog.path(), os.time() - 2 * 24 * 60 * 60))
package.loaded["utils.log"] = nil
local NextDayLog = require("utils.log")
NextDayLog.warn("new day")
NextDayLog.flush()
Stubs.flush()
file = assert(io.open(NextDayLog.path(), "r"))
content = file:read("*a")
file:close()
Assert.not_nil(content:find("[WARN] new day", 1, true))
Assert.is_nil(content:find("visible", 1, true))

Settings.save({ book_debug_enabled = original_debug })
