--[[--
配置接线：DataStorage → 测试沙箱数据目录，读配置走 moon.settings

@module tests.config_spec
--]]

local Assert = require("support.assert")
local Config = require("support.config")

Assert.not_nil(Config.root())
-- 数据目录必须是沙箱，绝不能指回模拟器 config/（测试会写坏真实配置）
Assert.eq(Config.dir(), (os.getenv("KO_HOME") or (Config.root() .. "/test")):gsub("/+$", ""))
Assert.is_nil(Config.dir():find("/config", 1, true))

do
    local DS = require("datastorage")
    Assert.eq(DS:getDataDir(), Config.dir())
end

if not Config.available() then
    Assert.skip("沙箱数据目录未就绪，请用 ./tests/run.sh 运行")
end

local Settings = Config.settings()
local common = Settings.get()
Assert.not_nil(common)
Assert.not_nil(common.active_source)
local common_file = Settings.get("common")
Assert.is_nil(common_file.ui_scale)
Assert.is_nil(common_file.lock_screen)
Assert.eq(type(Settings.get("display").ui_scale), "number")
Assert.eq(type(Settings.get("display").library_sort), "string")
Assert.eq(type(Settings.feature("lockscreen").lock_screen), "string")
Assert.eq(type(Settings.feature("panel").quick_panel_reader_actions), "table")
Assert.is_true(Settings.feature("translate").edge_translation_enabled)
Assert.is_true(Settings.feature("baike").baike_enabled)
Assert.is_true(Settings.get("reader").selection_handles_enabled)
Assert.is_false(Settings.get("reader").auto_mark_read_at_99)

local active = Settings.activeSourceId()
Assert.eq(active, common.active_source)

-- 传入部分平铺表只更新指定键，不应清掉其他分区的配置。
local original_sort = common.library_sort
Settings.save({ library_sort = "title" })
Assert.eq(Settings.get().library_sort, "title")
Assert.eq(Settings.get().active_source, active)
Settings.save({ library_sort = original_sort })

-- feature 配置不进平铺表；就地改 + saveSection 落盘。
Assert.is_nil(common.remote_idle_stop)
local remote = Settings.feature("remote")
Assert.is_true(remote.remote_idle_stop)
remote.remote_idle_stop = false
Settings.saveSection("remote")
package.loaded["utils.settings"] = nil
Settings = require("utils.settings")
Assert.is_false(Settings.feature("remote").remote_idle_stop)
Settings.feature("remote").remote_idle_stop = true
Settings.saveSection("remote")

-- 旧分区迁移：新进程首次 feature(name) 时把键搬进 settings/<name>.lua 并从旧分区删掉。
do
    local reader = Settings.get("reader")
    reader.baike_enabled = false
    reader.dictionary_enabled = false
    Settings.saveSection("reader", reader)
    local display = Settings.get("display")
    display.auto_night_lat = 31.2
    Settings.saveSection("display", display)
    Settings.saveSection("baike", {})
    Settings.saveSection("dictionary", { dictionary_enabled = true })
    Settings.saveSection("nightmode", {})

    package.loaded["utils.settings"] = nil
    Settings = require("utils.settings")
    Assert.is_false(Settings.feature("baike").baike_enabled, "旧值搬过来")
    Assert.is_true(Settings.feature("dictionary").dictionary_enabled, "新文件已有的值优先")
    local night = Settings.feature("nightmode")
    Assert.eq(night.auto_night_lat, 31.2, "keys 声明的无默认值键也要搬")
    Assert.eq(night.auto_night, "off", "缺的键补默认值")

    package.loaded["utils.settings"] = nil
    Settings = require("utils.settings")
    Assert.is_nil(Settings.get("reader").baike_enabled, "旧分区删除已落盘")
    Assert.is_nil(Settings.get("reader").dictionary_enabled)
    Assert.is_nil(Settings.get("display").auto_night_lat)
    Assert.is_false(Settings.feature("baike").baike_enabled, "迁移结果已落盘")
    Assert.eq(Settings.feature("nightmode").auto_night_lat, 31.2)

    Settings.saveSection("baike", { baike_enabled = true })
    Settings.saveSection("nightmode", {})
end

local src = Settings.getSource(active)
Assert.not_nil(src)
Assert.eq(type(src), "table")

-- 路径也应落在沙箱 .moon/settings
local Paths = require("utils.paths")
Assert.eq(Paths.root(), Config.dir() .. "/.moon")
Assert.eq(Paths.commonPath(), Config.dir() .. "/.moon/settings/common.lua")
Assert.eq(Paths.sectionPath("display"), Config.dir() .. "/.moon/settings/display.lua")
Assert.eq(Paths.logPath(), Config.dir() .. "/.moon/book.log")

-- 启动项：月读的取值落在 KOReader 的 start_with；取消回到 filemanager
do
    local previous = _G.G_reader_settings
    local store = {}
    _G.G_reader_settings = {
        readSetting = function(_, key, default)
            if store[key] == nil then return default end
            return store[key]
        end,
        saveSetting = function(_, key, value) store[key] = value end,
    }
    Assert.is_false(Settings.openOnStart(), "未设置时是 KOReader 默认 filemanager")
    Settings.setOpenOnStart(true)
    Assert.eq(store.start_with, "bookshelf_book", "已持久化的取值不能改")
    Assert.is_true(Settings.openOnStart())
    Settings.setOpenOnStart(false)
    Assert.eq(store.start_with, "filemanager")
    Assert.is_false(Settings.openOnStart())
    _G.G_reader_settings = previous
end
