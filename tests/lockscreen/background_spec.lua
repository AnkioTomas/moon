--[[--
lockscreen.background：背景模式与必应/摸鱼日报缓存。

@module tests.lockscreen.background_spec
--]]

local Assert = require("support.assert")

local settings = { lock_screen_background = "none" }
local files = {}
local download

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
    }
end
package.preload["ui/network/manager"] = function()
    return { isOnline = function() return true end }
end
package.preload["http.request"] = function()
    return {
        download = function(opts, dest, cb)
            download = { url = opts.url, dest = dest }
            local final = dest:gsub("%.part$", "")
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
        bookshelf = function()
            return { reading = {}, covers = {} }
        end,
    }
end
package.preload["lockscreen.render"] = function()
    return {
        size = function() return 480, 800 end,
        write = function(path)
            files[path] = { mode = "file", size = 128 }
            return true
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

Assert.is_true(Background.validMode("myrl"))
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

settings.lock_screen_background = "bing"
settings.lock_screen_bing_day = "1999-01-01"
download = nil
Background.ensure(function(path) got = path end)
Assert.not_nil(download)
Assert.is_true(tostring(download.url):find("bing", 1, true) ~= nil)
Assert.eq(got, Background.bingPath())

settings.lock_screen_background = "myrl"
settings.lock_screen_myrl_day = "1999-01-01"
download = nil
Background.ensure(function(path) got = path end)
Assert.not_nil(download)
Assert.is_true(tostring(download.url):find("myrl", 1, true) ~= nil)
Assert.eq(got, Background.myrlPath())

settings.lock_screen_background = "bookshelf"
Background.ensure(function(path) got = path end)
Assert.eq(got, Background.bookshelfPath())
