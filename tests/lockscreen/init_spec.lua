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

local MoonSettings = require("utils.settings")
local LockScreen = require("lockscreen.init")
local Myrl = require("lockscreen.styles.myrl")

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
    pcall(os.remove, Myrl.path())
    pcall(os.remove, Myrl.path() .. ".part")
    _G.G_reader_settings = previous_settings
end

local ok_run, err_run = pcall(function()
    -- 默认跟随
    common.lock_screen = nil
    common.lock_screen_prev_type = nil
    common.lock_screen_prev_cover = nil
    common.lock_screen_day = nil
    MoonSettings.save()
    Assert.eq(LockScreen.mode(), "ko")
    Assert.eq(LockScreen.label(), "跟随 KOReader")

    -- 选项 = 跟随系统 + 已注册样式（摸鱼日报在内）
    local opts = LockScreen.options()
    Assert.len(opts, 5)
    Assert.eq(opts[1].value, "ko")
    Assert.eq(opts[2].value, "myrl")
    Assert.eq(opts[3].value, "reading")
    Assert.eq(opts[4].value, "bill")
    Assert.eq(opts[5].value, "quote")
    Assert.eq(LockScreen.label("myrl"), "摸鱼日报")

    -- 用户原锁屏（开着「Sleeping」提示文字）
    saved.screensaver_type = "cover"
    saved.screensaver_document_cover = "/old/cover.png"
    saved.screensaver_show_message = true

    -- 新安装默认 myrl 由 bootstrap 接管，也必须先备份 KOReader 原配置。
    common.lock_screen = "myrl"
    MoonSettings.save()
    LockScreen.bootstrap()
    Assert.eq(common.lock_screen_prev_type, "cover")
    Assert.eq(common.lock_screen_prev_cover, "/old/cover.png")
    LockScreen.setMode("ko")
    Assert.eq(common.lock_screen, "ko", "明确选择跟随必须覆盖默认 myrl")

    LockScreen.setMode("myrl")
    -- 模式落盘不依赖网络
    Assert.eq(LockScreen.mode(), "myrl")
    -- 新风格尚未生成时必须撤下旧封面，不能残留上一种锁屏图。
    Assert.eq(saved.screensaver_type, "disable")
    Assert.is_nil(saved.screensaver_document_cover)
    Assert.is_true(saved.screensaver_show_message)

    local done, ok_dl
    LockScreen.refresh(function(ok)
        done = true
        ok_dl = ok
    end)
    Stubs.flush()
    Assert.is_true(done)
    Assert.is_true(ok_dl)
    Assert.eq(saved.screensaver_type, "document_cover")
    Assert.eq(saved.screensaver_document_cover, Myrl.path())
    -- 接管时关掉 KOReader 自带锁屏提示
    Assert.is_false(saved.screensaver_show_message)
    Assert.is_true(last_download.url:find("api%.ankio%.net/myrl", 1, false) ~= nil)
    Assert.is_true(last_download.url:find("width=480", 1, true) ~= nil)
    Assert.is_true(last_download.url:find("height=800", 1, true) ~= nil)

    -- 备份了原设置
    Assert.eq(MoonSettings.get().lock_screen_prev_type, "cover")
    Assert.eq(MoonSettings.get().lock_screen_prev_cover, "/old/cover.png")
    Assert.is_true(MoonSettings.get().lock_screen_prev_show_message)

    -- 配置仍为今日但文件被删：bootstrap 必须在后台重新下载
    pcall(os.remove, Myrl.path())
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

    -- 下一次锁屏预生成可显式绕过同一时间桶缓存。
    LockScreen.refresh(nil, true)
    Stubs.flush()
    Assert.not_nil(last_download.url)

    -- 跨天：标记是昨天的，文件还在也要重下（日报每日更新）
    common.lock_screen_day = "2000-01-01"
    MoonSettings.save()
    last_download.url = nil
    refreshed = nil
    LockScreen.refresh(function(ok)
        refreshed = ok
    end)
    Stubs.flush()
    Assert.is_true(refreshed)
    Assert.not_nil(last_download.url)
    Assert.eq(MoonSettings.get().lock_screen_day, os.date("%Y-%m-%d"))

    -- 离线选中：仍然落盘，只是不下载，等联网事件补
    online = false
    LockScreen.setMode("ko")
    LockScreen.setMode("myrl")
    Assert.eq(LockScreen.mode(), "myrl")
    last_download.url = nil
    LockScreen.refreshInBackground()
    Stubs.flush()
    Assert.is_nil(last_download.url)

    online = true
    LockScreen.refreshInBackground()
    Stubs.flush()
    Assert.not_nil(last_download.url)
    Assert.eq(saved.screensaver_document_cover, Myrl.path())

    -- 切回跟随：恢复（含锁屏提示设置）
    LockScreen.setMode("ko")
    Stubs.flush()
    Assert.eq(LockScreen.mode(), "ko")
    Assert.eq(saved.screensaver_type, "cover")
    Assert.eq(saved.screensaver_document_cover, "/old/cover.png")
    Assert.is_true(saved.screensaver_show_message)
    Assert.is_nil(MoonSettings.get().lock_screen_prev_type)
    Assert.is_nil(MoonSettings.get().lock_screen_prev_show_message)

    -- 未注册 id 回落到跟随系统，不留脏状态
    common.lock_screen = "no-such-style"
    MoonSettings.save()
    Assert.eq(LockScreen.mode(), "ko")
end)

cleanup()
if not ok_run then
    error(err_run)
end
