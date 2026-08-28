--[[--
配置文件只打开一次：UI.sz/UI.face 每次调用都读 ui_scale，
LuaSettings:open 每次都 dofile，重复打开会把页面构建变成几百次磁盘读。

@module tests.utils.settings_cache_spec
--]]

local Assert = require("support.assert")
local Config = require("support.config")

if not Config.available() then
    io.write("  (skip: 沙箱数据目录未就绪，请用 ./tests/run.sh 运行)\n")
    return
end

Assert.is_true(Config.setupNativePath())
Config.installUtilStub()

local LuaSettings = require("luasettings")
local Settings = Config.settings()

local opens = 0
local real_open = LuaSettings.open
LuaSettings.open = function(self, path)
    opens = opens + 1
    return real_open(self, path)
end

-- 先跑一次把已有实例算进基线之外
Settings.get()
opens = 0

for _ = 1, 200 do
    Settings.get()
end
Settings.activeSourceId()
Assert.eq(opens, 0)

local active = Settings.activeSourceId()
Settings.getSource(active)
local after_source = opens
for _ = 1, 50 do
    Settings.getSource(active)
end
Assert.eq(opens, after_source)

LuaSettings.open = real_open
