--[[--
features.lockscreen.settings：写入 KOReader screensaver_*

@module tests.features.lockscreen.settings_spec
--]]

local Assert = require("support.assert")
local Config = require("support.config")

if not Config.available() then
    Assert.skip("沙箱数据目录未就绪，请用 ./tests/run.sh 运行")
end

local saved = {}
local previous_settings = _G.G_reader_settings
_G.G_reader_settings = {
    readSetting = function(_, k)
        return saved[k]
    end,
    saveSetting = function(_, k, v)
        saved[k] = v
    end,
    delSetting = function(_, k)
        saved[k] = nil
    end,
}

local Settings = require("features.lockscreen.settings")

local ok_run, err_run = pcall(function()
    -- 用户原本自己设的锁屏方式：接管前必须被快照，clearCover 时原样还回去
    saved.screensaver_type = "cover"
    saved.screensaver_show_message = true

    -- applyCover：document_cover 接管并关掉提示文字
    local cover_path = "/tmp/moon-lockscreen-test-cover.png"
    local cover_file = assert(io.open(cover_path, "wb"))
    cover_file:write("cover")
    cover_file:close()
    Settings.applyCover(cover_path)
    Assert.eq(saved.screensaver_type, "document_cover")
    Assert.eq(saved.screensaver_document_cover, cover_path)
    Assert.is_false(saved.screensaver_show_message)

    saved.screensaver_type = "document_cover"
    saved.screensaver_document_cover = cover_path
    Settings.applyCover("/tmp/moon-lockscreen-missing-cover.png")
    Assert.eq(saved.screensaver_type, "document_cover")
    Assert.eq(saved.screensaver_document_cover, cover_path)
    Assert.is_true(saved.screensaver_show_message)
    os.remove(cover_path)

    -- clearCover：还原接管前的配置，而不是一律 disable
    Settings.clearCover()
    Assert.eq(saved.screensaver_type, "cover", "用户原本的锁屏方式必须还原")
    Assert.is_nil(saved.screensaver_document_cover, "原本没有的键要删掉")
    Assert.is_true(saved.screensaver_show_message)

    -- 显式 false 不是“缺失”：恢复后必须保留 false
    local false_file = assert(io.open(cover_path, "wb"))
    false_file:write("cover")
    false_file:close()
    saved.screensaver_show_message = false
    Settings.applyCover(cover_path)
    Settings.clearCover()
    Assert.is_false(saved.screensaver_show_message)
    os.remove(cover_path)

    -- 没接管过（无快照）时 clearCover 不许乱动用户配置
    saved.screensaver_type = "random_image"
    Settings.clearCover()
    Assert.eq(saved.screensaver_type, "random_image")

    -- 海报风格：非法值不落盘；合法值清掉旧图标记并推进版本号
    local MoonSettings = require("utils.settings")
    local previous_style = MoonSettings.get("features.lockscreen").lock_screen_poster_style
    MoonSettings.get("features.lockscreen").lock_screen_day = "stale"
    local rev = Settings.revision()
    Settings.setPosterStyle("bogus")
    Assert.eq(MoonSettings.get("features.lockscreen").lock_screen_poster_style, previous_style)
    Assert.eq(Settings.revision(), rev)
    Settings.setPosterStyle("slant_left")
    Assert.eq(MoonSettings.get("features.lockscreen").lock_screen_poster_style, "slant_left")
    Assert.is_nil(MoonSettings.get("features.lockscreen").lock_screen_day)
    Assert.eq(Settings.revision(), rev + 1)
    MoonSettings.get("features.lockscreen").lock_screen_poster_style = previous_style

    -- 选图 / 选文件夹同样作废旧图，下次生成按新路径。
    local conf = MoonSettings.get("features.lockscreen")
    local previous_image, previous_folder = conf.lock_screen_custom_image, conf.lock_screen_folder
    conf.lock_screen_day = "stale"
    Settings.setCustomImage("/mnt/us/me.png")
    Assert.eq(conf.lock_screen_custom_image, "/mnt/us/me.png")
    Assert.is_nil(conf.lock_screen_day)
    conf.lock_screen_day = "stale"
    Settings.setFolder("/mnt/us/walls")
    Assert.eq(conf.lock_screen_folder, "/mnt/us/walls")
    Assert.is_nil(conf.lock_screen_day)
    conf.lock_screen_custom_image, conf.lock_screen_folder = previous_image, previous_folder

    -- 背景主体拆分：旧的自带背景主体搬成「背景, 主体」，只迁一次。
    local previous_bg, previous_component, previous_split =
        conf.lock_screen_background, conf.lock_screen_component, conf.lock_screen_split
    local cases = {
        { "myrl", "myrl", "none" },
        { "poster", "poster", "none" },
        { "cover_card", "cover", "capsule" },
        { "minimal", "none", "minimal" },
        { "current", "bing", "current" },
    }
    for _idx, case in ipairs(cases) do
        conf.lock_screen_split, conf.lock_screen_background, conf.lock_screen_component = nil, "bing", case[1]
        Settings.migrate()
        Assert.eq(conf.lock_screen_background, case[2], case[1])
        Assert.eq(conf.lock_screen_component, case[3], case[1])
        Assert.is_true(conf.lock_screen_split)
    end
    -- 迁过之后用户给极简另选背景，不得被改回白底。
    conf.lock_screen_background = "bing"
    Settings.migrate()
    Assert.eq(conf.lock_screen_background, "bing")
    conf.lock_screen_background, conf.lock_screen_component, conf.lock_screen_split =
        previous_bg, previous_component, previous_split
    MoonSettings.save("features.lockscreen")
end)

_G.G_reader_settings = previous_settings
if not ok_run then
    error(err_run)
end
