--[[--
lockscreen.background：显式背景模式与必应每日更新。

@module tests.lockscreen.background_spec
--]]

local Assert = require("support.assert")
local settings = { lock_screen_background = "none" }
local files = {}
local download

package.preload["utils.paths"] = function()
    return {
        lockScreenCustomPath = function() return "/moon/lock_screen/custom.png" end,
        lockScreenDir = function() return "/moon/lock_screen" end,
        ensureLockScreenDir = function() end,
    }
end
package.preload["utils.settings"] = function()
    return { get = function() return settings end, save = function() end }
end
package.preload["libs/libkoreader-lfs"] = function()
    return { attributes = function(path) return files[path] end }
end
package.preload["ui/network/manager"] = function()
    return { isOnline = function() return true end }
end
package.preload["http.request"] = function()
    return {
        download = function(opts, dest)
            download = { opts = opts, dest = dest }
            return { cancel = function() end }
        end,
    }
end
package.loaded["lockscreen.background"] = nil

local Background = require("lockscreen.background")
local got = false
Background.ensure(function(path) got = path or false end)
Assert.is_false(got)
Assert.is_nil(download)

settings.lock_screen_background = "custom"
files[Background.customPath()] = { mode = "file", size = 100 }
Background.ensure(function(path) got = path end)
Assert.eq(got, Background.customPath())
Assert.is_nil(download)

settings.lock_screen_background = "bing"
settings.lock_screen_bing_day = "2000-01-01"
files[Background.bingPath()] = { mode = "file", size = 100 }
Background.ensure(function() end)
Assert.is_true(download.opts.allow_redirects)
Assert.matches(download.dest, "bing%.jpg%.part$")
