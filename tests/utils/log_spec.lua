--[[--
插件独立日志：级别、落盘批次、启动 logo 与跨天清理。

@module tests.utils.log_spec
--]]

local Assert = require("support.assert")
local Config = require("support.config")
local Stubs = require("support.stubs")

if not Config.available() then
    Assert.skip("沙箱数据目录未就绪，请用 ./tests/run.sh 运行")
end

package.preload["utils.log"] = nil
package.loaded["utils.log"] = nil
local Log = require("utils.log")
local log_path = require("utils.paths").logPath()
os.remove(log_path)
Log.info("hello", 7)
Log.dbg("hidden")
Log.warn("careful")
Log.error("broken")

local file = assert(io.open(log_path, "r"))
local content = file:read("*a")
file:close()
Assert.is_nil(content:find("[INFO] hello 7", 1, true))
Assert.is_nil(content:find("[WARN] careful", 1, true))
Assert.is_nil(content:find("hidden", 1, true))

-- info 计入批次：hello + careful + broken + batch 3–8 = 9 条，尚未落盘
for i = 3, 8 do Log.warn("batch", i) end
Stubs.flush()
file = assert(io.open(log_path, "r"))
content = file:read("*a")
file:close()
Assert.eq(content, "")

Log.warn("batch", 9)
Log.warn("tail", 10)
Log.flush()
file = assert(io.open(log_path, "r"))
content = file:read("*a")
file:close()
Assert.eq(content, "")
Stubs.flush()
file = assert(io.open(log_path, "r"))
content = file:read("*a")
file:close()
Assert.not_nil(content:find("[INFO] hello 7", 1, true))
Assert.not_nil(content:find("[WARN] careful", 1, true))
Assert.not_nil(content:find("[ERROR] broken", 1, true))
Assert.not_nil(content:find("[WARN] batch 9", 1, true))
Assert.not_nil(content:find("[WARN] tail 10", 1, true))
Assert.is_nil(content:find("hidden", 1, true))
Assert.is_nil(content:find("[DEBUG]", 1, true))

-- 同一天重启继续追加，崩溃后的下一次启动不能先把诊断证据删掉。
package.loaded["utils.log"] = nil
local RestartedLog = require("utils.log")
RestartedLog.info("fresh")
RestartedLog.flush()
Stubs.flush()
file = assert(io.open(log_path, "r"))
content = file:read("*a")
file:close()
Assert.not_nil(content:find("[INFO] fresh", 1, true))
Assert.not_nil(content:find("[INFO] hello 7", 1, true))

-- 跨天首次启动才清空旧日志，避免日志无限增长。
local lfs = require("libs/libkoreader-lfs")
Assert.is_true(lfs.touch(log_path, os.time() - 2 * 24 * 60 * 60))
package.loaded["utils.log"] = nil
local NextDayLog = require("utils.log")
NextDayLog.warn("new day")
NextDayLog.flush()
Stubs.flush()
file = assert(io.open(log_path, "r"))
content = file:read("*a")
file:close()
Assert.not_nil(content:find("[WARN] new day", 1, true))
Assert.is_nil(content:find("hello 7", 1, true))

-- 启动横幅立即排入落盘：先写无前缀的字符串 logo，再写可检索的 BOOT 元数据行。
package.preload["version"] = function() return { getShortVersion = function() return "v2026.07.2" end } end
package.preload["device"] = function()
    return { model = "KindlePaperWhite2", isKindle = function() return true end }
end
package.loaded["version"], package.loaded["device"] = nil, nil
package.loaded["utils.mem"] = nil
NextDayLog.boot()
Stubs.flush()
file = assert(io.open(log_path, "r"))
content = file:read("*a")
file:close()
Assert.not_nil(content:find("██████████▄▄███████████████████████", 1, true), "logo crescent arm")
Assert.not_nil(content:find("█████▀▀████████▀▀██▄", 1, true), "logo face gaps")
Assert.not_nil(content:find("▄▄█████████▀", 1, true), "logo inner cap")
Assert.not_nil(content:find("月读 · Moon", 1, true), "logo wordmark")
local function bootLine(sub)
    for line in (content .. "\n"):gmatch("([^\n]*)\n") do
        if line:find(sub, 1, true) then return line end
    end
end
local arm = bootLine("██████████▄▄███████████████████████")
local mark = bootLine("月读 · Moon")
Assert.not_nil(arm)
Assert.not_nil(mark)
Assert.is_nil(arm:match("^%d%d%d%d%-%d%d%-%d%d"), "logo lines must not be timestamp-prefixed")
Assert.is_nil(mark:match("^%d%d%d%d%-%d%d%-%d%d"), "wordmark must not be timestamp-prefixed")
Assert.not_nil(content:find("[BOOT] moon " .. require("bookversion") .. " koreader v2026.07.2 device KindlePaperWhite2 startup_mode framework", 1, true))

