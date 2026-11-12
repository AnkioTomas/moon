---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

--[[--
书摘编辑页配置：声明在 features.share.setting，读写立刻 flush；新进程再读仍是上次的选项。

@module tests.features.share.settings_spec
--]]

local Assert = require("support.assert")
local Paths = require("utils.paths")

local function reload()
    package.loaded["utils.settings"] = nil
    package.loaded["features.share.settings"] = nil
    package.loaded["features.share.setting"] = nil
    return require("features.share.settings"), require("utils.settings")
end

os.remove(Paths.sectionPath("share"))
local Settings, MoonSettings = reload()

-- 尚无文件时吃默认值。
local fresh = Settings.read()
Assert.eq(fresh.theme, "calendar")
Assert.eq(fresh.swatch, "default")
Assert.is_nil(fresh.long)
Assert.is_true(fresh.show_logo)
Assert.is_nil(fresh.font_id)
Assert.is_nil(fresh.art)

Settings.write({
    theme = "scenic",
    font_id = "KingHwa_OldSong",
    font_name = "京华老宋体",
    swatch = "paper",
    art = "window",
    show_logo = false,
})

local conf = MoonSettings.get("features.share")
Assert.eq(conf.share_theme, "scenic")
Assert.eq(conf.share_font, "KingHwa_OldSong")
Assert.eq(conf.share_font_name, "京华老宋体")
Assert.eq(conf.share_swatch, "paper")
Assert.eq(conf.share_art, "window")
Assert.is_false(conf.share_long)
Assert.is_false(conf.share_show_logo)

-- 立刻 flush，不等自动保存间隔。
local path = Paths.sectionPath("share")
local f = assert(io.open(path, "r"))
local body = f:read("*a")
f:close()
Assert.is_true(body:find("scenic", 1, true) ~= nil, "主题已写入磁盘")
Assert.is_true(body:find("KingHwa_OldSong", 1, true) ~= nil, "字体 id 已写入磁盘")
Assert.is_true(body:find("window", 1, true) ~= nil, "插画已写入磁盘")

-- 模拟下次打开：丢掉进程内缓存，从磁盘再读。
Settings, MoonSettings = reload()
local loaded = Settings.read()
Assert.eq(loaded.theme, "scenic")
Assert.eq(loaded.font_id, "KingHwa_OldSong")
Assert.eq(loaded.font_name, "京华老宋体")
Assert.eq(loaded.swatch, "paper")
Assert.eq(loaded.art, "window")
Assert.is_nil(loaded.long)
Assert.is_false(loaded.show_logo)

-- 改回自动字体立刻清掉 id。
Settings.write({
    theme = "classic",
    swatch = "default",
    show_logo = true,
})
Settings, MoonSettings = reload()
loaded = Settings.read()
Assert.eq(loaded.theme, "classic")
Assert.is_nil(loaded.font_id)
Assert.is_nil(loaded.font_name)
Assert.is_nil(loaded.art)
Assert.is_nil(loaded.long)
Assert.is_true(loaded.show_logo)

-- 旧配置：夜读/公众号长图/长卡片打开后要能迁移，不把编辑页弄坏。
Settings.write({
    theme = "calendar",
    swatch = "default",
    show_logo = true,
})
local raw = MoonSettings.get("features.share")
raw.share_theme = "night"
raw.share_swatch = "default"
raw.share_long = true
MoonSettings.save("features.share")
Settings, MoonSettings = reload()
local migrated = Settings.read()
Assert.eq(migrated.theme, "paper")
Assert.eq(migrated.swatch, "night")
Assert.is_nil(migrated.long)

raw = MoonSettings.get("features.share")
raw.share_theme = "official"
raw.share_swatch = "blue"
MoonSettings.save("features.share")
Settings, MoonSettings = reload()
migrated = Settings.read()
Assert.eq(migrated.theme, "paper")
Assert.eq(migrated.swatch, "blue")

Settings.write({ theme = "night", swatch = "removed", font_id = "", font_name = "旧字体" })
Settings, MoonSettings = reload()
local normalized = Settings.read()
Assert.eq(normalized.theme, "paper")
Assert.eq(normalized.swatch, "night", "未知色板先回落默认，再迁移旧夜读")
Assert.is_nil(normalized.font_id)
Assert.is_nil(normalized.font_name)
Assert.is_true(normalized.show_logo)

os.remove(Paths.sectionPath("share"))
return true
