--[[--
配置文件只打开一次：Theme.px 每次调用都读 ui_scale，
LuaSettings:open 每次都 dofile，重复打开会把页面构建变成几百次磁盘读。

@module tests.utils.settings_cache_spec
--]]

local Assert = require("support.assert")
local Config = require("support.config")

if not Config.available() then
    Assert.skip("沙箱数据目录未就绪，请用 ./tests/run.sh 运行")
end

Config.installUtilStub()

local LuaSettings = require("luasettings")
local Settings = Config.settings()

local opens = 0
local real_open = LuaSettings.open
LuaSettings.open = function(self, path)
    opens = opens + 1
    return real_open(self, path)
end

-- 先跑一次把已有实例（含迁移扫过的旧分区）算进基线之外
Settings.get("ui")
opens = 0

for _ = 1, 200 do
    Settings.get("ui")
end
Assert.eq(opens, 0)

Settings.getSource("local")
local after_source = opens
for _ = 1, 50 do
    Settings.getSource("local")
end
Assert.eq(opens, after_source)

LuaSettings.open = real_open
