--[[--
lockscreen.background：背景模式与必应/摸鱼日报缓存。

@module tests.lockscreen.background_spec
--]]

local Assert = require("support.assert")

local settings = { lock_screen_background = "none" }
local files = {}
local download
local online = true

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
package.preload["ui/network/manager"] = function()
    return { isOnline = function() return online end }
end
package.preload["http.request"] = function()
    return {
        download = function(opts, dest, cb)
            download = { url = opts.url, dest = dest }
            local final = dest:gsub("%.part$", "")
            files[dest] = { mode = "file", size = 64 }
            files[final] = { mode = "file", size = 64 }
            -- background does os.rename(tmp, cached)
            local real_rename = os.rename
            os.rename = function(a, b)
                files[b] = files[a] or { mode = "file", size = 64 }
                files[a] = nil
                return true
            end
            cb(true)
            os.rename = real_rename
            return { cancel = function() end }
        end,
    }
end
package.preload["lockscreen.context"] = function()
    return {
        currentBook = function()
            return { cover = "/tmp/cover.png" }
        end,
    }
end
package.preload["lockscreen.layout"] = function()
    return {
        portraitSize = function() return 480, 800 end,
        dayKey = function() return "2020-01-02" end,
    }
end

package.loaded["lockscreen.background"] = nil
local Background = require("lockscreen.background")

Assert.is_false(Background.validMode("myrl"))
Assert.is_false(Background.validMode("nope"))

settings.lock_screen_background = "none"
local got
Background.ensure(function(path) got = path end)
Assert.is_nil(got)

settings.lock_screen_background = "custom"
files[Background.customPath()] = { mode = "file", size = 32 }
Background.ensure(function(path) got = path end)
Assert.eq(got, Background.customPath())

settings.lock_screen_background = "cover"
files["/tmp/cover.png"] = { mode = "file", size = 32 }
Background.ensure(function(path) got = path end)
Assert.eq(got, "/tmp/cover.png")

-- 当前书无封面：fileOk(nil) 不得炸 attributes
package.loaded["lockscreen.context"] = nil
package.preload["lockscreen.context"] = function()
    return {
        currentBook = function()
            return { title = "no-cover" }
        end,
    }
end
package.loaded["lockscreen.background"] = nil
Background = require("lockscreen.background")
got = "sentinel"
Background.ensure(function(path) got = path end)
Assert.is_nil(got)

settings.lock_screen_background = "bing"
settings.lock_screen_bing_day = "1999-01-01"
download = nil
Background.ensure(function(path) got = path end)
Assert.not_nil(download)
Assert.is_true(tostring(download.url):find("bing", 1, true) ~= nil)
Assert.eq(got, Background.bingPath())

settings.lock_screen_background = "bing"
settings.lock_screen_myrl_day = "1999-01-01"
download = nil
Background.ensureMyrl(function(path) got = path end)
Assert.not_nil(download)
Assert.is_true(tostring(download.url):find("myrl", 1, true) ~= nil)
Assert.eq(got, Background.myrlPath())

-- 网络背景没有旧图时不能把纯白 compose 图标记成当天成功。
settings.lock_screen_background = "bing"
settings.lock_screen_bing_day = nil
files[Background.bingPath()] = nil
online = false
local background_error
got = "sentinel"
Background.ensure(function(path, err)
    got, background_error = path, err
end)
Assert.is_nil(got)
Assert.not_nil(background_error)
online = true

-- folder：空目录
settings.lock_screen_background = "folder"
settings.lock_screen_folder_day = nil
settings.lock_screen_folder_pick = nil
files[Background.folderDir()] = { mode = "directory" }
files[Background.folderDir() .. "/__dir__"] = { ".", ".." }
got = "sentinel"
Background.ensure(function(path) got = path end)
Assert.is_nil(got)

-- folder：按日复用
local wall = Background.folderDir() .. "/a.png"
files[Background.folderDir() .. "/__dir__"] = { ".", "..", "a.png", "b.jpg" }
files[wall] = { mode = "file", size = 64 }
files[Background.folderDir() .. "/b.jpg"] = { mode = "file", size = 64 }
Background.ensure(function(path) got = path end)
Assert.not_nil(got)
local first = got
Background.ensure(function(path) got = path end)
Assert.eq(got, first)
Assert.eq(settings.lock_screen_folder_pick, first)
