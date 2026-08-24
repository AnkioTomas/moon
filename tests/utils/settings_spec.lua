--[[--
配置接线：DataStorage → config/，读配置走 moon.settings

@module tests.config_spec
--]]

local Assert = require("support.assert")
local Config = require("support.config")

Assert.not_nil(Config.root())
Assert.eq(Config.dir(), Config.root() .. "/config")

do
    local DS = require("datastorage")
    Assert.eq(DS:getDataDir(), Config.dir())
end

if not Config.available() then
    io.write("  (skip: config/ 软链不可用)\n")
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
-- 快捷面板迁移标记必须是 quickpanel 段的持久化键，否则布局改名迁移会反复执行。
Assert.not_nil(Settings.get("quickpanel").quick_panel_reader_action_layout_renamed)

local active = Settings.activeSourceId()
Assert.eq(active, common.active_source)

local src = Settings.getSource(active)
Assert.not_nil(src)
Assert.eq(type(src), "table")

-- 路径也应落在 config/.moon/settings
local Paths = require("utils.paths")
Assert.eq(Paths.root(), Config.dir() .. "/.moon")
Assert.eq(Paths.commonPath(), Config.dir() .. "/.moon/settings/common.lua")
Assert.eq(Paths.sectionPath("display"), Config.dir() .. "/.moon/settings/display.lua")
