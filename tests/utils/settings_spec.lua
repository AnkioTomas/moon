--[[--
配置框架：拥有者声明默认值（<owner>/setting.lua），落盘 settings/<末段>.lua，
首次打开从拆分前的旧分区搬键；末段重名报错。数据目录是测试沙箱。

@module tests.utils.settings_spec
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

local LuaSettings = require("luasettings")
local Paths = require("utils.paths")
local Settings = Config.settings()

local function reload()
    package.loaded["utils.settings"] = nil
    Settings = require("utils.settings")
end

--- 直接写旧分区文件（绕过框架），模拟拆分前留下的配置。
local function legacy(name, values)
    local ls = LuaSettings:open(name == "common" and Paths.commonPath() or Paths.sectionPath(name))
    for key, value in pairs(values) do ls.data[key] = value end
    ls:flush()
    return ls
end

local function legacyData(name)
    return LuaSettings:open(name == "common" and Paths.commonPath() or Paths.sectionPath(name)).data
end

-- 默认值来自各拥有者的 setting.lua
Assert.eq(type(Settings.get("source").active_source), "string")
Assert.eq(type(Settings.get("store").zlib_enabled), "boolean")
Assert.eq(type(Settings.get("ui").ui_scale), "number")
Assert.eq(type(Settings.get("desktop").library_sort), "string")
Assert.eq(type(Settings.get("desktop").home_topbar_items), "table")
Assert.eq(type(Settings.get("desktop.pages.home").home_recent_list_rows), "number")
Assert.eq(type(Settings.get("utils").book_debug_enabled), "boolean")
Assert.eq(type(Settings.get("ai").ai_model), "string")
Assert.is_true(Settings.get("reader").selection_handles_enabled)
Assert.is_false(Settings.get("reader").auto_mark_read_at_99)
Assert.eq(type(Settings.get("features.lockscreen").lock_screen), "string")
Assert.eq(type(Settings.get("features.panel").quick_panel_reader_actions), "table")
Assert.is_true(Settings.get("features.translate").edge_translation_enabled)
Assert.is_true(Settings.get("features.baike").baike_enabled)
-- 每个拥有者只拿到自己的键
Assert.is_nil(Settings.get("ui").library_sort)
Assert.is_nil(Settings.get("desktop.pages.home").home_topbar_items)

-- 文件名 = 拥有者路径末段；两个拥有者撞同一个文件直接报错
Assert.errors(function() Settings.get("features.reader") end, "owned by both reader and features.reader")

-- 就地改 + save 落盘，新进程读得到
local remote = Settings.get("features.remote")
Assert.is_true(remote.remote_idle_stop)
remote.remote_idle_stop = false
Settings.save("features.remote")
reload()
Assert.is_false(Settings.get("features.remote").remote_idle_stop)
Settings.get("features.remote").remote_idle_stop = true
Settings.save("features.remote")

-- 核心拥有者的旧分区迁移：common / display / home 里属于别人的键搬走，自己文件里的不动
do
    Settings.save("source", {})
    Settings.save("ui", {})
    Settings.save("desktop", {})
    legacy("common", { active_source = "moon", enabled_sources = { moon = true } })
    legacy("display", { ui_scale = 150, ui_theme = "ink", library_sort = "title" })
    legacy("home", { home_topbar_items = { clock = false }, home_recent_list_rows = 3 })

    reload()
    Assert.eq(Settings.get("source").active_source, "moon")
    Assert.is_true(Settings.get("source").enabled_sources.moon, "keys 声明的无默认值键也要搬")
    Assert.eq(Settings.get("ui").ui_scale, 150)
    Assert.eq(Settings.get("ui").ui_theme, "ink")
    Assert.is_true(Settings.get("ui").mesh_mask, "缺的键补默认值")
    Assert.eq(Settings.get("desktop").library_sort, "title")
    Assert.is_false(Settings.get("desktop").home_topbar_items.clock)
    Assert.eq(Settings.get("desktop.pages.home").home_recent_list_rows, 3, "自己的文件不当旧分区搬")

    reload()
    Assert.is_nil(legacyData("common").active_source, "旧分区删除已落盘")
    Assert.is_nil(legacyData("common").enabled_sources)
    Assert.is_nil(legacyData("display").ui_scale)
    Assert.is_nil(legacyData("display").library_sort)
    Assert.is_nil(legacyData("home").home_topbar_items)
    Assert.eq(legacyData("home").home_recent_list_rows, 3)
    Assert.eq(Settings.get("source").active_source, "moon", "迁移结果已落盘")

    Settings.save("source", {})
    Settings.save("ui", {})
    Settings.save("desktop", {})
    Settings.get("desktop.pages.home").home_recent_list_rows = 2
    Settings.save("desktop.pages.home")
    reload()
end

-- feature 的旧分区迁移同一规则：新文件已有的值优先
do
    -- save(owner, values) 会先完成迁移再覆盖，所以先清空新文件、再往旧分区写值
    Settings.save("features.baike", {})
    Settings.save("features.dictionary", { dictionary_enabled = true })
    Settings.save("features.nightmode", {})
    local reader = Settings.get("reader")
    reader.baike_enabled = false
    reader.dictionary_enabled = false
    Settings.save("reader")
    legacy("display", { auto_night_lat = 31.2 })

    reload()
    Assert.is_false(Settings.get("features.baike").baike_enabled, "旧值搬过来")
    Assert.is_true(Settings.get("features.dictionary").dictionary_enabled, "新文件已有的值优先")
    local night = Settings.get("features.nightmode")
    Assert.eq(night.auto_night_lat, 31.2, "keys 声明的无默认值键也要搬")
    Assert.eq(night.auto_night, "off", "缺的键补默认值")

    reload()
    Assert.is_nil(Settings.get("reader").baike_enabled, "旧分区删除已落盘")
    Assert.is_nil(Settings.get("reader").dictionary_enabled)
    Assert.is_nil(legacyData("display").auto_night_lat)
    Assert.eq(Settings.get("features.nightmode").auto_night_lat, 31.2)

    Settings.save("features.baike", { baike_enabled = true })
    Settings.save("features.nightmode", {})
end

Assert.eq(type(Settings.getSource("local")), "table")

-- 路径也应落在沙箱 .moon/settings
Assert.eq(Paths.root(), Config.dir() .. "/.moon")
Assert.eq(Paths.commonPath(), Config.dir() .. "/.moon/settings/common.lua")
Assert.eq(Paths.sectionPath("ui"), Config.dir() .. "/.moon/settings/ui.lua")
Assert.eq(Paths.logPath(), Config.dir() .. "/.moon/book.log")
