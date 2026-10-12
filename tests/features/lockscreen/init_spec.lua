--[[--
lockscreen：组合模式切换 / 接管 / 生成落盘

不碰真网络：stub http.request.download 写本地 PNG。

@module tests.features.lockscreen.init_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
local Config = require("support.config")

if not Config.available() then
    Assert.skip("沙箱数据目录未就绪，请用 ./tests/run.sh 运行")
end

package.preload["device"] = function()
    return {
        screen = {
            getWidth = function() return 480 end,
            getHeight = function() return 800 end,
            isColorEnabled = function() return false end,
        },
    }
end

local PNG8 = "\137PNG\r\n\26\n" .. string.rep("\0", 24)
local last_download = {}
local render_writes = 0
local cover_a = "/tmp/moon-lockscreen-cover-a.png"
local cover_b = "/tmp/moon-lockscreen-cover-b.png"
local current_cover = cover_a
local logs = {}

package.preload["utils.log"] = function()
    local function capture(...)
        local parts = {}
        for i = 1, select("#", ...) do
            parts[i] = tostring(select(i, ...))
        end
        logs[#logs + 1] = table.concat(parts, " ")
    end
    return { dbg = capture, warn = capture }
end

package.preload["ui/renderimage"] = function()
    return {
        renderImageFile = function(_, path)
            local file = io.open(path, "rb")
            if not file then return nil end
            local data = file:read("*a")
            file:close()
            if not data or #data <= 8 then return nil end
            return { free = function() end }
        end,
    }
end

local function stubOnlineImage(name, ext)
    local ready = false
    local path
    return {
        imageFile = function()
            path = path or (require("utils.paths").onlineCacheDir() .. "/" .. name .. "." .. ext)
            return path
        end,
        imagePath = function(self)
            return ready and self:imageFile() or nil
        end,
        imageReady = function()
            return ready
        end,
        ensureImage = function(self, cb)
            path = self:imageFile()
            require("utils.paths").ensureOnlineCache()
            last_download.url = "https://api.ankio.net/" .. name
            last_download.dest = path
            local file = assert(io.open(path, "wb"))
            file:write(PNG8)
            file:close()
            ready = true
            local job = { cancel = function() end }
            require("ui/uimanager"):nextTick(function()
                cb(path)
            end)
            return job
        end,
        invalidateImage = function(self)
            ready = false
            os.remove(self:imageFile())
        end,
    }
end
package.preload["online.bing"] = function()
    return stubOnlineImage("bing", "jpg")
end
package.preload["online.myrl"] = function()
    return stubOnlineImage("myrl", "png")
end

local online = true
package.preload["ui/network/manager"] = function()
    return {
        isOnline = function()
            return online
        end,
        isConnected = function()
            return online
        end,
    }
end

package.preload["features.lockscreen.components.current"] = function()
    return {
        book = function()
            return { cover = current_cover }
        end,
    }
end

package.preload["features.lockscreen.render"] = function()
    return {
        size = function() return 480, 800 end,
        measureText = function() return 40 end,
        write = function(path)
            render_writes = render_writes + 1
            local f = assert(io.open(path, "wb"))
            f:write(PNG8)
            f:close()
            return true
        end,
    }
end

local setup_seen = {}
local Screensaver = {
    setup = function(_self, event)
        setup_seen[#setup_seen + 1] = { event = event, writes = render_writes }
    end,
}
package.preload["ui/screensaver"] = function() return Screensaver end

local saved = {}
local previous_settings = _G.G_reader_settings
_G.G_reader_settings = {
    readSetting = function(_, k) return saved[k] end,
    saveSetting = function(_, k, v) saved[k] = v end,
    delSetting = function(_, k) saved[k] = nil end,
}

package.loaded["online.bing"] = nil
package.loaded["online.myrl"] = nil
package.loaded["ui/network/manager"] = nil
package.loaded["features.lockscreen.background"] = nil
package.loaded["features.lockscreen.compose"] = nil
package.loaded["features.lockscreen.components.current"] = nil
package.loaded["features.lockscreen"] = nil
package.loaded["features.lockscreen.render"] = nil
package.loaded["features.lockscreen.settings"] = nil
package.loaded["utils.log"] = nil

local MoonSettings = require("utils.settings")

-- 用临时目录隔离 screensaver 文件，避免测试删除/覆盖真实的 config/.moon/screensaver
local Paths = require("utils.paths")
local lfs = require("libs/libkoreader-lfs")
local TEST_SCREENSAVER = "/tmp/moon-lockscreen-screensaver"
local function ensureTestScreensaver()
    if lfs.attributes(TEST_SCREENSAVER, "mode") ~= "directory" then
        lfs.mkdir(TEST_SCREENSAVER)
    end
end
ensureTestScreensaver()
Paths.screensaverDir = function() return TEST_SCREENSAVER end
Paths.ensureScreensaverDir = ensureTestScreensaver

local LockScreen = require("features.lockscreen")
local Settings = require("features.lockscreen.settings")
local Compose = require("features.lockscreen.compose")
local compose_path = Paths.screensaverDir() .. "/compose.png"

local conf = MoonSettings.get("features.lockscreen")
local prev = {
    lock_screen = conf.lock_screen,
    lock_screen_day = conf.lock_screen_day,
    lock_screen_background = conf.lock_screen_background,
    lock_screen_component = conf.lock_screen_component,
    lock_screen_position = conf.lock_screen_position,
    lock_screen_wide = conf.lock_screen_wide,
}

local function cleanup()
    for k, v in pairs(prev) do conf[k] = v end
    MoonSettings.save("features.lockscreen")
    pcall(os.remove, compose_path)
    pcall(os.remove, require("utils.paths").onlineCacheDir() .. "/myrl.png")
    pcall(os.remove, require("utils.paths").onlineCacheDir() .. "/myrl.json")
    pcall(os.remove, require("utils.paths").onlineCacheDir() .. "/bing.jpg")
    pcall(os.remove, require("utils.paths").onlineCacheDir() .. "/bing.json")
    pcall(os.remove, cover_a)
    pcall(os.remove, cover_b)
    _G.G_reader_settings = previous_settings
end

local ok_run, err_run = pcall(function()
    conf.lock_screen = "ko"
    conf.lock_screen_day = nil
    conf.lock_screen_background = "bing"
    conf.lock_screen_component = "current"
    MoonSettings.save("features.lockscreen")
    pcall(os.remove, compose_path)

    Assert.is_false(Settings.isCompose())

    saved.screensaver_type = "cover"
    saved.screensaver_document_cover = "/old/cover.png"
    saved.screensaver_show_message = true

    -- 残留 compose.png 不得让 setMode 立刻 applyCover：新图生成前保持用户原配置
    -- （以前这里会写 disable，把用户自己设的锁屏方式永久关掉）
    require("utils.paths").ensureScreensaverDir()
    local stale = assert(io.open(compose_path, "wb"))
    stale:write(PNG8)
    stale:close()
    Settings.setMode("compose")
    Assert.is_true(Settings.isCompose())
    Assert.eq(conf.lock_screen, "compose")
    Assert.eq(saved.screensaver_type, "cover", "尚未接管前不得改动用户锁屏方式")
    Assert.eq(saved.screensaver_document_cover, "/old/cover.png")

    -- 账单是完整报告卡：固定居中、固定宽屏，但不能污染其他主体的布局偏好。
    local previous_position = conf.lock_screen_position
    local previous_wide = conf.lock_screen_wide
    conf.lock_screen_wide = false
    Settings.setComponent("bill")
    conf.lock_screen_position = "top-left"
    MoonSettings.save("features.lockscreen")
    Assert.eq(Compose.plan().position, "center-center")
    Assert.is_true(Compose.plan().wide)
    Assert.is_false(conf.lock_screen_wide)
    Settings.setPosition("bottom-right")
    Assert.eq(conf.lock_screen_position, "top-left")
    Settings.setWide(true)
    Assert.is_false(conf.lock_screen_wide)
    Settings.setComponent("message")
    Assert.eq(Compose.plan().component.id, "message")
    Assert.is_false(Compose.plan().wide)
    Settings.setComponent("bill")
    conf.lock_screen_position = previous_position
    conf.lock_screen_wide = previous_wide
    MoonSettings.save("features.lockscreen")
    local done, ok_dl
    LockScreen.refresh(function(ok)
        done = true
        ok_dl = ok
    end)
    Stubs.flush()
    Assert.is_true(done)
    Assert.is_true(ok_dl)
    Assert.eq(saved.screensaver_type, "document_cover")
    Assert.eq(saved.screensaver_document_cover, compose_path)
    Assert.is_false(saved.screensaver_show_message)
    Assert.matches(table.concat(logs, "\n"), "book%.lockscreen refresh start request")
    Assert.matches(table.concat(logs, "\n"), "book%.lockscreen refresh done request")

    -- 缓存命中
    last_download.url = nil
    render_writes = 0
    local refreshed
    LockScreen.refresh(function(ok) refreshed = ok end)
    Stubs.flush()
    Assert.is_true(refreshed)
    Assert.eq(render_writes, 0)
    Assert.matches(table.concat(logs, "\n"),
        "book%.lockscreen refresh skipped request cache_hit")

    -- 强制刷新必须绕过当天缓存，保证动态主体能更新。
    LockScreen.refresh(nil, true)
    Stubs.flush()
    Assert.is_true(render_writes > 0)

    -- myrl 主体触网；日报不再是独立背景。图归 online。
    Settings.setBackgroundMode("bing")
    Settings.setComponent("myrl")
    Assert.eq(Compose.plan().background_mode, "bing")
    Assert.eq(Compose.plan().asset.id, "myrl")
    local myrl_img = require("utils.paths").onlineCacheDir() .. "/myrl.png"
    require("online.myrl"):invalidateImage()
    last_download.url = nil
    LockScreen.refresh(function(ok) refreshed = ok end)
    Stubs.flush()
    Assert.is_true(refreshed)
    Assert.not_nil(last_download.url)
    Assert.is_true(tostring(last_download.url):find("myrl", 1, true) ~= nil)
    Assert.eq(saved.screensaver_document_cover, myrl_img)
    Assert.eq(saved.screensaver_document_cover ~= compose_path, true)

    -- 图丢了必须再下，即使组合日标记还在。
    require("online.myrl"):invalidateImage()
    last_download.url = nil
    LockScreen.refresh(function(ok) refreshed = ok end)
    Stubs.flush()
    Assert.is_true(refreshed)
    Assert.is_true(tostring(last_download.url):find("myrl", 1, true) ~= nil)

    -- 当前书籍封面参与缓存键：同一天切换书籍也要重绘。
    local file_a = assert(io.open(cover_a, "wb"))
    file_a:write(PNG8)
    file_a:close()
    local file_b = assert(io.open(cover_b, "wb"))
    file_b:write(PNG8)
    file_b:close()
    Settings.setBackgroundMode("cover")
    Settings.setComponent("none")
    LockScreen.refresh(function(ok) refreshed = ok end)
    Stubs.flush()
    Assert.is_true(refreshed)
    render_writes = 0
    current_cover = cover_b
    LockScreen.refresh(function(ok) refreshed = ok end)
    Stubs.flush()
    Assert.is_true(refreshed)
    Assert.is_true(render_writes > 0)

    -- KOReader 先 Screensaver:setup 再发 Suspend：钩子必须在原生 setup 读设置前把图生成好，
    -- 否则锁屏永远显示上一轮的内容；内容没变时命中缓存不重画；关机 / 重启画面不生成。
    LockScreen.onCreate()
    LockScreen.onCreate()
    Stubs.flush()
    render_writes = 0
    current_cover = cover_a
    Screensaver:setup()
    Assert.len(setup_seen, 1, "钩子只装一次")
    Assert.eq(setup_seen[1].writes, 1, "原生 setup 之前已经重画")
    Assert.eq(saved.screensaver_document_cover, compose_path)
    Screensaver:setup()
    Assert.eq(setup_seen[2].writes, 1, "内容没变：缓存命中，不重画")
    current_cover = cover_b
    Screensaver:setup("poweroff")
    Assert.eq(setup_seen[3].event, "poweroff")
    Assert.eq(setup_seen[3].writes, 1, "关机画面不生成锁屏图")

    -- 在飞生成期间改配置：旧任务作废，新请求必须重开，不能被 already_running 吞掉。
    local Background = require("features.lockscreen.background")
    local first, second
    Settings.setBackgroundMode("bing")
    Background.invalidate(Compose.plan().asset)
    LockScreen.refresh(function(ok) first = ok end)
    Settings.setBackgroundMode("cover")
    Assert.eq(saved.screensaver_type, "cover", "改配置先撤下旧图")
    LockScreen.refresh(function(ok) second = ok end)
    Stubs.flush()
    Assert.is_nil(first, "过期任务已被取消，不再回调")
    Assert.is_true(second)
    Assert.eq(saved.screensaver_type, "document_cover")

    online = false
    last_download.url = nil
    LockScreen.refresh()
    Stubs.flush()
    Assert.is_nil(last_download.url)

    online = true
    -- 切回 KOReader 锁屏：撤下接管并还原用户接管前的配置
    Settings.setMode("ko")
    Assert.is_false(Settings.isCompose())
    Assert.eq(saved.screensaver_type, "cover", "接管前的锁屏方式必须还原")
    Assert.eq(saved.screensaver_document_cover, "/old/cover.png")
    Assert.is_true(saved.screensaver_show_message)
end)

cleanup()
if not ok_run then
    error(err_run)
end
