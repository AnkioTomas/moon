--[[--
配置接线：DataStorage → 测试沙箱数据目录，读配置走 moon.settings

@module tests.config_spec
--]]

local Assert = require("support.assert")
local Config = require("support.config")

Assert.not_nil(Config.root())
-- 数据目录必须是沙箱，绝不能指回模拟器 config/（测试会写坏真实配置）
Assert.matches(Config.dir(), "/test$")
Assert.is_nil(Config.dir():find("/config", 1, true))

do
    local DS = require("datastorage")
    Assert.eq(DS:getDataDir(), Config.dir())
end

if not Config.available() then
    io.write("  (skip: 沙箱数据目录未就绪，请用 ./tests/run.sh 运行)\n")
    return
end

Assert.is_true(Config.setupNativePath())

local Settings = Config.settings()
local common = Settings.get()
Assert.not_nil(common)
Assert.not_nil(common.active_source)
local common_file = Settings.get("common")
Assert.is_nil(common_file.ui_scale)
Assert.is_nil(common_file.lock_screen)
Assert.eq(type(Settings.get("display").ui_scale), "number")
Assert.eq(type(Settings.get("lockscreen").lock_screen), "string")
Assert.eq(type(Settings.get("quickpanel").quick_panel_reader_actions), "table")

local active = Settings.activeSourceId()
Assert.eq(active, common.active_source)

local src = Settings.getSource(active)
Assert.not_nil(src)
Assert.eq(type(src), "table")

-- 路径也应落在沙箱 .moon/settings
local Paths = require("utils.paths")
Assert.eq(Paths.root(), Config.dir() .. "/.moon")
Assert.eq(Paths.commonPath(), Config.dir() .. "/.moon/settings/common.lua")
Assert.eq(Paths.sectionPath("display"), Config.dir() .. "/.moon/settings/display.lua")
