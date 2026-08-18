--[[--
lockscreen.settings：模式读写 / 接管与恢复 KOReader screensaver_*

@module tests.lockscreen.settings_spec
--]]

local Assert = require("support.assert")
local Config = require("support.config")

if not Config.available() then
    io.write("  (skip: config/ 软链不可用)\n")
    return
end

Assert.is_true(Config.setupNativePath())

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

local MoonSettings = require("utils.settings")
local Settings = require("lockscreen.settings")

-- 隔离本测对 common 的改动
local common = MoonSettings.get()
local prev_lock = common.lock_screen
local prev_type = common.lock_screen_prev_type
local prev_cover = common.lock_screen_prev_cover
local prev_show_message = common.lock_screen_prev_show_message
local prev_day = common.lock_screen_day

local function cleanup()
    common.lock_screen = prev_lock
    common.lock_screen_prev_type = prev_type
    common.lock_screen_prev_cover = prev_cover
    common.lock_screen_prev_show_message = prev_show_message
    common.lock_screen_day = prev_day
    MoonSettings.save()
    _G.G_reader_settings = previous_settings
end

local ok_run, err_run = pcall(function()
    common.lock_screen = nil
    common.lock_screen_prev_type = nil
    common.lock_screen_prev_cover = nil
    common.lock_screen_prev_show_message = nil
    common.lock_screen_day = nil
    MoonSettings.save()

    -- 模式读写
    Assert.is_nil(Settings.mode())
    Settings.setMode("myrl")
    Assert.eq(Settings.mode(), "myrl")
    Settings.setMode(nil)
    Assert.eq(Settings.mode(), "ko")

    -- applyCover：document_cover 接管并关掉提示文字
    Settings.applyCover("/tmp/a.png")
    Assert.eq(saved.screensaver_type, "document_cover")
    Assert.eq(saved.screensaver_document_cover, "/tmp/a.png")
    Assert.is_false(saved.screensaver_show_message)

    Settings.clearCover()
    Assert.eq(saved.screensaver_type, "disable")
    Assert.is_nil(saved.screensaver_document_cover)
    Assert.is_true(saved.screensaver_show_message)

    -- 备份只发生一次
    saved.screensaver_type = "cover"
    saved.screensaver_document_cover = "/old/cover.png"
    saved.screensaver_show_message = true
    Settings.backupIfNeeded()
    Assert.eq(common.lock_screen_prev_type, "cover")
    Assert.eq(common.lock_screen_prev_cover, "/old/cover.png")
    Assert.is_true(common.lock_screen_prev_show_message)
    saved.screensaver_type = "document_cover"
    Settings.backupIfNeeded()
    Assert.eq(common.lock_screen_prev_type, "cover")

    -- 恢复并清空备份
    Settings.restorePrev()
    Assert.eq(saved.screensaver_type, "cover")
    Assert.eq(saved.screensaver_document_cover, "/old/cover.png")
    Assert.is_true(saved.screensaver_show_message)
    Assert.is_nil(common.lock_screen_prev_type)
    Assert.is_nil(common.lock_screen_prev_cover)
    Assert.is_nil(common.lock_screen_prev_show_message)

    -- 原设置无自定义封面：恢复时删掉 key 而不是写空串
    Settings.backupIfNeeded()
    saved.screensaver_document_cover = nil
    common.lock_screen_prev_type = "cover"
    common.lock_screen_prev_cover = ""
    MoonSettings.save()
    Settings.restorePrev()
    Assert.is_nil(saved.screensaver_document_cover)

    -- KOReader 尚未初始化 screensaver_* 时，恢复仍应回到透明背景 + 提示框默认行为。
    saved = {}
    common.lock_screen_prev_type = nil
    common.lock_screen_prev_cover = nil
    common.lock_screen_prev_show_message = nil
    MoonSettings.save()
    Settings.backupIfNeeded()
    Assert.eq(common.lock_screen_prev_type, "disable")
    Assert.is_true(common.lock_screen_prev_show_message)
    saved.screensaver_show_message = false
    Settings.restorePrev()
    Assert.eq(saved.screensaver_type, "disable")
    Assert.is_true(saved.screensaver_show_message)

    -- 下载日标记读写
    Assert.is_nil(Settings.savedDay())
    Settings.setSavedDay("2024-01-01")
    Assert.eq(Settings.savedDay(), "2024-01-01")
    Settings.setSavedDay(nil)
    Assert.is_nil(Settings.savedDay())
end)

cleanup()
if not ok_run then
    error(err_run)
end
