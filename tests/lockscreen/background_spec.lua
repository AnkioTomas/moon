--[[--
lockscreen.background：背景模式与必应/摸鱼日报缓存。

@module tests.lockscreen.background_spec
--]]

local Assert = require("support.assert")

local settings = { lock_screen_background = "none", lock_screen_asset_cache = {} }
local files = {}
local download
local download_count = 0
local download_valid = true
local online = true
local original_date = os.date
os.date = function() return "2020-01-02" end

package.preload["utils.paths"] = function()
    return {
        screensaverDir = function() return "/tmp/moon-screensaver" end,
        ensureScreensaverDir = function() end,
    }
end
package.preload["utils.settings"] = function()
    return {
        get = function() return settings end,
        save = function() end,
    }
end
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path)
            return files[path]
        end,
        dir = function(path)
            local names = files[path .. "/__dir__"] or {}
            local i = 0
            return function()
                i = i + 1
                return names[i]
            end
        end,
    }
end
package.preload["ui/renderimage"] = function()
    return {
        renderImageFile = function(_, path)
            local attr = files[path]
            if not attr or not attr.valid then
                return nil
            end
            return { free = function() end }
        end,
    }
end
package.preload["ui/network/manager"] = function()
    return { isOnline = function() return online end }
end
package.preload["http.request"] = function()
    return {
        download = function(opts, dest, cb)
            download = { url = opts.url, dest = dest }
            download_count = download_count + 1
            files[dest] = { mode = "file", size = 64, valid = download_valid }
            -- background does os.rename(tmp, cached)
            local real_rename = os.rename
            os.rename = function(a, b)
                files[b] = files[a]
                files[a] = nil
                return true
            end
            cb(true)
            os.rename = real_rename
            return { cancel = function() end }
        end,
    }
end
package.preload["lockscreen.components.current"] = function()
    return {
        book = function()
            return { cover = "/tmp/cover.png" }
        end,
    }
end
package.preload["lockscreen.layout"] = function()
    return {
        portraitSize = function() return 480, 800 end,
    }
end

package.loaded["lockscreen.background"] = nil
local Background = require("lockscreen.background")
local function background(mode)
    return Background.background(mode)
end
local function resourcePath(mode)
    return Background.resolve(background(mode))
end
local screen_dir = require("utils.paths").screensaverDir()
local folder_dir = screen_dir .. "/wallpapers"
local myrl_path = "/tmp/moon-screensaver/myrl.png"
local myrl = Background.daily{
    id = "myrl",
    path = function() return myrl_path end,
    request = function()
        return { url = "https://api.ankio.net/myrl", method = "GET", timeout = 60 }
    end,
}

Assert.is_false(Background.validMode("myrl"))
Assert.is_false(Background.validMode("nope"))

settings.lock_screen_background = "none"
local got
Background.ensure(background("none"), function(path) got = path end)
Assert.is_nil(got)

settings.lock_screen_background = "custom"
files[resourcePath("custom")] = { mode = "file", size = 32 }
Background.ensure(background("custom"), function(path) got = path end)
Assert.eq(got, resourcePath("custom"))

settings.lock_screen_background = "cover"
files["/tmp/cover.png"] = { mode = "file", size = 32 }
Background.ensure(background("cover"), function(path) got = path end)
Assert.eq(got, "/tmp/cover.png")

-- 当前书无封面：fileOk(nil) 不得炸 attributes
package.loaded["lockscreen.components.current"] = nil
package.preload["lockscreen.components.current"] = function()
    return {
        book = function()
            return { title = "no-cover" }
        end,
    }
end
package.loaded["lockscreen.background"] = nil
Background = require("lockscreen.background")
got = "sentinel"
Background.ensure(background("cover"), function(path) got = path end)
Assert.is_nil(got)

settings.lock_screen_background = "bing"
settings.lock_screen_asset_cache.bing = { day = "1999-01-01" }
download = nil
Background.ensure(background("bing"), function(path) got = path end)
Assert.not_nil(download)
Assert.is_true(tostring(download.url):find("bing", 1, true) ~= nil)
Assert.eq(got, resourcePath("bing"))

settings.lock_screen_background = "bing"
settings.lock_screen_asset_cache.myrl = { day = "1999-01-01" }
download = nil
Background.ensure(myrl, function(path) got = path end)
Assert.not_nil(download)
Assert.is_true(tostring(download.url):find("myrl", 1, true) ~= nil)
Assert.eq(got, myrl_path)

-- 下载返回足够大的错误内容或损坏图片时不能记成当天成功；下一次
-- ensure 必须再次发起请求，而不是被错误的日期标记短路。
settings.lock_screen_background = "bing"
settings.lock_screen_asset_cache.bing = nil
files[resourcePath("bing")] = nil
download_valid = false
download_count = 0
got = "sentinel"
local invalid_error
Background.ensure(background("bing"), function(path, err)
    got, invalid_error = path, err
end)
Assert.is_nil(got)
Assert.not_nil(invalid_error)
Assert.is_nil(settings.lock_screen_asset_cache.bing)
Assert.eq(download_count, 1)

download_valid = true
got = nil
Background.ensure(background("bing"), function(path, err)
    got, invalid_error = path, err
end)
Assert.eq(got, resourcePath("bing"))
Assert.is_nil(invalid_error)
Assert.eq(download_count, 2)
Assert.eq(settings.lock_screen_asset_cache.bing.day, "2020-01-02")

-- 网络背景没有旧图时不能把纯白 compose 图标记成当天成功。
settings.lock_screen_background = "bing"
settings.lock_screen_asset_cache.bing = nil
files[resourcePath("bing")] = nil
online = false
local background_error
got = "sentinel"
Background.ensure(background("bing"), function(path, err)
    got, background_error = path, err
end)
Assert.is_nil(got)
Assert.not_nil(background_error)
online = true

-- folder：空目录
settings.lock_screen_background = "folder"
settings.lock_screen_asset_cache.folder = nil
files[folder_dir] = { mode = "directory", modification = 1 }
files[folder_dir .. "/__dir__"] = { ".", ".." }
got = "sentinel"
Background.ensure(background("folder"), function(path) got = path end)
Assert.is_nil(got)

-- folder：按日复用
local wall = folder_dir .. "/a.png"
files[folder_dir] = { mode = "directory", modification = 2 }
files[folder_dir .. "/__dir__"] = { ".", "..", "a.png", "b.jpg" }
files[wall] = { mode = "file", size = 64 }
files[folder_dir .. "/b.jpg"] = { mode = "file", size = 64 }
Background.ensure(background("folder"), function(path) got = path end)
Assert.not_nil(got)
local first = got
Background.ensure(background("folder"), function(path) got = path end)
Assert.eq(got, first)
Assert.eq(settings.lock_screen_asset_cache.folder.path, first)

-- 任意新 ID 都能复用同一套每日资源生命周期，不依赖具体主体名称。
local custom_daily_path = "/tmp/moon-screensaver/new-style.png"
local custom_daily = Background.daily{
    id = "new-style",
    path = function() return custom_daily_path end,
    request = function()
        return { url = "https://example.test/new-style" }
    end,
}
settings.lock_screen_asset_cache["new-style"] = { day = "1999-01-01" }
files[custom_daily_path] = nil
download_valid = true
Background.ensure(custom_daily, function(path) got = path end)
Assert.eq(got, custom_daily_path)
Assert.eq(settings.lock_screen_asset_cache["new-style"].day, "2020-01-02")

os.date = original_date
