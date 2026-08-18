--[[--
lockscreen.settings：模式读写 / 写入 KOReader screensaver_*

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
local prev_day = common.lock_screen_day

local function cleanup()
    common.lock_screen = prev_lock
    common.lock_screen_day = prev_day
    MoonSettings.save()
    _G.G_reader_settings = previous_settings
end

local ok_run, err_run = pcall(function()
    common.lock_screen = nil
    common.lock_screen_day = nil
    MoonSettings.save()

    -- 模式读写
    Assert.is_nil(Settings.mode())
    Settings.setMode("myrl")
    Assert.eq(Settings.mode(), "myrl")
    Settings.setMode(nil)
    Assert.eq(Settings.mode(), "ko")

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

    Settings.clearCover()
    Assert.eq(saved.screensaver_type, "disable")
    Assert.is_nil(saved.screensaver_document_cover)
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
