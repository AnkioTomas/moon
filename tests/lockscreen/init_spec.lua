--[[--
lockscreen：模式切换 / 接管与恢复 / 下载落盘

不碰真网络：stub http.request.download 写本地 PNG。

@module tests.lockscreen.init_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
local Config = require("support.config")

if not Config.available() then
    io.write("  (skip: config/ 软链不可用)\n")
    return
end

Assert.is_true(Config.setupNativePath())

-- Device.screen 竖屏尺寸
package.preload["device"] = function()
    return {
        screen = {
            getWidth = function() return 480 end,
            getHeight = function() return 800 end,
        },
    }
end

local PNG8 = "\137PNG\r\n\26\n" .. string.rep("\0", 24)

local last_download = {}
package.preload["http.request"] = function()
    return {
        download = function(opts, dest, cb)
            last_download.url = opts and opts.url
            last_download.dest = dest
            local f = assert(io.open(dest, "wb"))
            f:write(PNG8)
            f:close()
            local job = { cancel = function() end }
            require("ui/uimanager"):nextTick(function()
                cb(true)
            end)
            return job
        end,
    }
end

local online = true
package.preload["ui/network/manager"] = function()
    return {
        isOnline = function()
            return online
        end,
    }
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

local Paths = require("utils.paths")
local MoonSettings = require("utils.settings")
local LockScreen = require("lockscreen.init")

-- 隔离本测对 common 的改动
local common = MoonSettings.get()
local prev_lock = common.lock_screen
local prev_type = common.lock_screen_prev_type
local prev_cover = common.lock_screen_prev_cover
local prev_day = common.lock_screen_myrl_day

local function cleanup()
    common.lock_screen = prev_lock
    common.lock_screen_prev_type = prev_type
    common.lock_screen_prev_cover = prev_cover
    common.lock_screen_myrl_day = prev_day
    MoonSettings.save()
    pcall(os.remove, LockScreen.imagePath())
    pcall(os.remove, LockScreen.imagePath() .. ".part")
    _G.G_reader_settings = previous_settings
end

local ok_run, err_run = pcall(function()
    -- 默认跟随
    common.lock_screen = nil
    common.lock_screen_prev_type = nil
    common.lock_screen_prev_cover = nil
    common.lock_screen_myrl_day = nil
    MoonSettings.save()
    Assert.eq(LockScreen.mode(), LockScreen.MODE_KO)
    Assert.eq(LockScreen.label(), "跟随 KOReader")

    -- 用户原锁屏
    saved.screensaver_type = "cover"
    saved.screensaver_document_cover = "/old/cover.png"

    LockScreen.setMode(LockScreen.MODE_MYRL)
    -- 模式落盘不依赖网络
    Assert.eq(LockScreen.mode(), LockScreen.MODE_MYRL)

    local done, ok_dl
    LockScreen.refresh(function(ok)
        done = true
        ok_dl = ok
    end)
    Stubs.flush()
    Assert.is_true(done)
    Assert.is_true(ok_dl)
    Assert.eq(saved.screensaver_type, "document_cover")
    Assert.eq(saved.screensaver_document_cover, LockScreen.imagePath())
    Assert.is_true(last_download.url:find("api%.ankio%.net/myrl", 1, false) ~= nil)
    Assert.is_true(last_download.url:find("width=480", 1, true) ~= nil)
    Assert.is_true(last_download.url:find("height=800", 1, true) ~= nil)

    -- 备份了原设置
    Assert.eq(MoonSettings.get().lock_screen_prev_type, "cover")
    Assert.eq(MoonSettings.get().lock_screen_prev_cover, "/old/cover.png")

    -- 配置仍为今日但文件被删：bootstrap 必须在后台重新下载
    pcall(os.remove, LockScreen.imagePath())
    last_download.url = nil
    LockScreen.bootstrap()
    Assert.is_nil(last_download.url) -- 下一拍执行，不阻塞启动
    Stubs.flush()
    Assert.not_nil(last_download.url)

    -- 同日再 refresh 不重复下载
    last_download.url = nil
    local refreshed
    LockScreen.refresh(function(ok)
        refreshed = ok
    end)
    Stubs.flush()
    Assert.is_true(refreshed)
    Assert.is_nil(last_download.url)

    -- 离线选中：仍然落盘，只是不下载，等联网事件补
    online = false
    LockScreen.setMode(LockScreen.MODE_KO)
    LockScreen.setMode(LockScreen.MODE_MYRL)
    Assert.eq(LockScreen.mode(), LockScreen.MODE_MYRL)
    last_download.url = nil
    LockScreen.refreshInBackground()
    Stubs.flush()
    Assert.is_nil(last_download.url)

    online = true
    LockScreen.refreshInBackground()
    Stubs.flush()
    Assert.not_nil(last_download.url)
    Assert.eq(saved.screensaver_document_cover, LockScreen.imagePath())

    -- 切回跟随：恢复
    LockScreen.setMode(LockScreen.MODE_KO)
    Stubs.flush()
    Assert.eq(LockScreen.mode(), LockScreen.MODE_KO)
    Assert.eq(saved.screensaver_type, "cover")
    Assert.eq(saved.screensaver_document_cover, "/old/cover.png")
    Assert.is_nil(MoonSettings.get().lock_screen_prev_type)
end)

cleanup()
if not ok_run then
    error(err_run)
end
