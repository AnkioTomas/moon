--[[--
lockscreen：组合模式切换 / 接管 / 生成落盘

不碰真网络：stub http.request.download 写本地 PNG。

@module tests.lockscreen.init_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
local Config = require("support.config")

if not Config.available() then
    io.write("  (skip: 沙箱数据目录未就绪，请用 ./tests/run.sh 运行)\n")
    return
end

Assert.is_true(Config.setupNativePath())

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
local render_writes = 0
local cover_a = "/tmp/moon-lockscreen-cover-a.png"
local cover_b = "/tmp/moon-lockscreen-cover-b.png"
local current_cover = cover_a

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
        get = function(_url, _opts, cb)
            require("ui/uimanager"):nextTick(function()
                cb('{"hitokoto":"测试一言","from":"出处","from_who":"作者"}')
            end)
            return { cancel = function() end }
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

package.preload["lockscreen.components.current"] = function()
    return {
        book = function()
            return { cover = current_cover }
        end,
    }
end

package.preload["lockscreen.render"] = function()
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

local saved = {}
local previous_settings = _G.G_reader_settings
_G.G_reader_settings = {
    readSetting = function(_, k) return saved[k] end,
    saveSetting = function(_, k, v) saved[k] = v end,
    delSetting = function(_, k) saved[k] = nil end,
}

package.loaded["http.request"] = nil
package.loaded["ui/network/manager"] = nil
package.loaded["lockscreen.background"] = nil
package.loaded["lockscreen.compose"] = nil
package.loaded["lockscreen.components.current"] = nil
package.loaded["lockscreen.init"] = nil
package.loaded["lockscreen.render"] = nil
package.loaded["lockscreen.settings"] = nil

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

local LockScreen = require("lockscreen.init")
local Settings = require("lockscreen.settings")
local Compose = require("lockscreen.compose")
local compose_path = Paths.screensaverDir() .. "/compose.png"

local common = MoonSettings.get()
local previous_asset_cache = {}
for key, value in pairs(common.lock_screen_asset_cache or {}) do
    if type(value) == "table" then
        previous_asset_cache[key] = {}
        for nested_key, nested_value in pairs(value) do
            previous_asset_cache[key][nested_key] = nested_value
        end
    else
        previous_asset_cache[key] = value
    end
end
local prev = {
    lock_screen = common.lock_screen,
    lock_screen_day = common.lock_screen_day,
    lock_screen_asset_cache = previous_asset_cache,
    lock_screen_background = common.lock_screen_background,
    lock_screen_component = common.lock_screen_component,
    lock_screen_position = common.lock_screen_position,
    lock_screen_wide = common.lock_screen_wide,
}

local function cleanup()
    for k, v in pairs(prev) do common[k] = v end
    MoonSettings.save()
    pcall(os.remove, compose_path)
    pcall(os.remove, require("utils.paths").screensaverDir() .. "/myrl.png")
    pcall(os.remove, cover_a)
    pcall(os.remove, cover_b)
    _G.G_reader_settings = previous_settings
end

local ok_run, err_run = pcall(function()
    common.lock_screen = "ko"
    common.lock_screen_day = nil
    common.lock_screen_background = "bing"
    common.lock_screen_component = "current"
    MoonSettings.save()
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
    Assert.eq(common.lock_screen, "compose")
    Assert.eq(saved.screensaver_type, "cover", "尚未接管前不得改动用户锁屏方式")
    Assert.eq(saved.screensaver_document_cover, "/old/cover.png")

    -- 账单是完整报告卡，位置固定居中，且底层 API 不能写入位置配置。
    local previous_position = common.lock_screen_position
    Settings.setComponent("bill")
    common.lock_screen_position = "top-left"
    MoonSettings.save()
    Assert.eq(Compose.plan().position, "center-center")
    Settings.setPosition("bottom-right")
    Assert.eq(common.lock_screen_position, "top-left")
    Settings.setComponent("current")
    common.lock_screen_position = previous_position
    MoonSettings.save()
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

    -- 缓存命中
    last_download.url = nil
    render_writes = 0
    local refreshed
    LockScreen.refresh(function(ok) refreshed = ok end)
    Stubs.flush()
    Assert.is_true(refreshed)
    Assert.eq(render_writes, 0)

    -- 强制刷新必须绕过当天缓存，保证动态主体能更新。
    LockScreen.refresh(nil, true)
    Stubs.flush()
    Assert.is_true(render_writes > 0)

    -- myrl 主体触网；日报不再是独立背景。
    Settings.setBackgroundMode("bing")
    Settings.setComponent("myrl")
    Assert.eq(Compose.plan().background_mode, "bing")
    Assert.eq(Compose.plan().asset.id, "myrl")
    common.lock_screen_asset_cache.myrl = nil
    MoonSettings.save()
    pcall(os.remove, require("utils.paths").screensaverDir() .. "/myrl.png")
    last_download.url = nil
    LockScreen.refresh(function(ok) refreshed = ok end)
    Stubs.flush()
    Assert.is_true(refreshed)
    Assert.not_nil(last_download.url)
    Assert.is_true(tostring(last_download.url):find("myrl", 1, true) ~= nil)
    Assert.eq(saved.screensaver_document_cover,
        require("utils.paths").screensaverDir() .. "/myrl.png")
    Assert.eq(saved.screensaver_document_cover ~= compose_path, true)

    -- 即使组合图已经是当天版本，日报下载标记过期也必须再次请求。
    common.lock_screen_asset_cache.myrl = { day = "1999-01-01" }
    MoonSettings.save()
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
