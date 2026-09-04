--[[--
插件独立日志：级别、调试开关与重启清理。

@module tests.utils.log_spec
--]]

local Assert = require("support.assert")
local Config = require("support.config")

if not Config.available() then
    io.write("  (skip: 沙箱数据目录未就绪，请用 ./tests/run.sh 运行)\n")
    return
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
Assert.not_nil(content:find("[WARN] careful", 1, true))
Assert.not_nil(content:find("[ERROR] broken", 1, true))
Assert.is_nil(content:find("hidden", 1, true))

Settings.save({ book_debug_enabled = true })
Log.dbg("visible")
Log.info("hello", 7)
file = assert(io.open(Log.path(), "r"))
content = file:read("*a")
file:close()
Assert.not_nil(content:find("[DEBUG] visible", 1, true))
Assert.not_nil(content:find("[INFO] hello 7", 1, true))

-- 重新加载模块等同插件进程重启：旧日志必须在第一次写入前被截断。
package.loaded["utils.log"] = nil
local RestartedLog = require("utils.log")
RestartedLog.info("fresh")
file = assert(io.open(RestartedLog.path(), "r"))
content = file:read("*a")
file:close()
Assert.not_nil(content:find("[INFO] fresh", 1, true))
Assert.is_nil(content:find("visible", 1, true))

Settings.save({ book_debug_enabled = original_debug })
