--[[--
features.lockscreen.background：背景模式；必应/摸鱼日报图交给 online。

@module tests.features.lockscreen.background_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")

local settings = { lock_screen_background = "none" }
local files = {}
local original_date = os.date
local today = { year = 2020, month = 1, day = 2 }
os.date = function(fmt)
    if fmt == "*t" then return { year = today.year, month = today.month, day = today.day } end
    return string.format("%04d-%02d-%02d", today.year, today.month, today.day)
end

local bing_path = "/tmp/moon-online-cache/bing.jpg"
local myrl_path = "/tmp/moon-online-cache/myrl.png"
local bing_ready = false
local myrl_ready = false
local bing_ensures = 0
local myrl_ensures = 0

package.preload["utils.paths"] = function()
    return {
        screensaverDir = function() return "/tmp/moon-screensaver" end,
        ensureScreensaverDir = function() end,
        onlineCacheDir = function() return "/tmp/moon-online-cache" end,
        ensureOnlineCache = function() end,
    }
end
package.preload["utils.settings"] = function()
    return {
        get = function(name) assert(name == "features.lockscreen"); return settings end,
        save = function(name) assert(name == "features.lockscreen") end,
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
package.preload["online.bing"] = function()
    return {
        imageFile = function() return bing_path end,
        imagePath = function() return bing_ready and bing_path or nil end,
        imageReady = function() return bing_ready end,
        ensureImage = function(_, cb)
            bing_ensures = bing_ensures + 1
            if bing_ready then
                cb(bing_path)
                return
            end
            files[bing_path] = { mode = "file", size = 64, valid = true }
            bing_ready = true
            cb(bing_path)
        end,
        invalidateImage = function()
            bing_ready = false
            files[bing_path] = nil
        end,
    }
end
package.preload["online.myrl"] = function()
    return {
        imageFile = function() return myrl_path end,
        imagePath = function() return myrl_ready and myrl_path or nil end,
        imageReady = function() return myrl_ready end,
        ensureImage = function(_, cb)
            myrl_ensures = myrl_ensures + 1
            if myrl_ready then
                cb(myrl_path)
                return
            end
            files[myrl_path] = { mode = "file", size = 64, valid = true }
            myrl_ready = true
            cb(myrl_path)
        end,
        invalidateImage = function()
            myrl_ready = false
            files[myrl_path] = nil
        end,
    }
end
package.preload["features.lockscreen.components.current"] = function()
    return {
        book = function()
            return { cover = "/tmp/cover.png" }
        end,
    }
end
package.preload["features.lockscreen.layout"] = function()
    return {
        portraitSize = function() return 480, 800 end,
    }
end

package.loaded["features.lockscreen.background"] = nil
local Background = require("features.lockscreen.background")
local function background(mode)
    return Background.background(mode)
end
local function resourcePath(mode)
    return Background.resolve(background(mode))
end
local screen_dir = require("utils.paths").screensaverDir()
local folder_dir = screen_dir .. "/wallpapers"

Assert.is_false(Background.validMode("myrl"))
Assert.is_false(Background.validMode("nope"))
Assert.eq(resourcePath("bing"), bing_path)

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
package.loaded["features.lockscreen.components.current"] = nil
package.preload["features.lockscreen.components.current"] = function()
    return {
        book = function()
            return { title = "no-cover" }
        end,
    }
end
package.loaded["features.lockscreen.background"] = nil
Background = require("features.lockscreen.background")
got = "sentinel"
Background.ensure(background("cover"), function(path) got = path end)
Assert.is_nil(got)

settings.lock_screen_background = "bing"
bing_ready = false
bing_ensures = 0
Background.ensure(background("bing"), function(path) got = path end)
Assert.eq(bing_ensures, 1)
Assert.eq(got, bing_path)
Assert.is_true(Background.isFresh(background("bing")))

local myrl = {
    id = "myrl",
    path = function() return myrl_path end,
    endpoint = "myrl",
    network = true,
}
myrl_ready = false
myrl_ensures = 0
Background.ensure(myrl, function(path) got = path end)
Assert.eq(myrl_ensures, 1)
Assert.eq(got, myrl_path)

Background.invalidate(background("bing"))
Assert.is_false(Background.isFresh(background("bing")))
bing_ensures = 0
Background.ensure(background("bing"), function(path) got = path end)
Assert.eq(bing_ensures, 1)
Assert.eq(got, bing_path)

-- folder：空目录
settings.lock_screen_background = "folder"
files[folder_dir] = { mode = "directory", modification = 1 }
files[folder_dir .. "/__dir__"] = { ".", ".." }
got = "sentinel"
Background.ensure(background("folder"), function(path) got = path end)
Assert.is_nil(got)

-- folder：同一天固定一张，第二天换下一张，不落盘任何状态
local wall = folder_dir .. "/a.png"
files[folder_dir] = { mode = "directory", modification = 2 }
files[folder_dir .. "/__dir__"] = { ".", "..", "a.png", "b.jpg", "notes.txt" }
files[wall] = { mode = "file", size = 64 }
files[folder_dir .. "/b.jpg"] = { mode = "file", size = 64 }
files[folder_dir .. "/notes.txt"] = { mode = "file", size = 64 }
Background.ensure(background("folder"), function(path) got = path end)
local first = got
Assert.is_true(first == wall or first == folder_dir .. "/b.jpg", "只挑图片")
Background.ensure(background("folder"), function(path) got = path end)
Assert.eq(got, first)
today.day = 3
Background.ensure(background("folder"), function(path) got = path end)
Assert.is_true(got ~= first, "隔天轮换")
today.day = 2
Assert.is_nil(settings.lock_screen_asset_cache)

-- 用户选的文件夹 / 自定义图优先于默认位置
local picked = "/mnt/us/wallpapers"
settings.lock_screen_folder = picked
files[picked] = { mode = "directory", modification = 1 }
files[picked .. "/__dir__"] = { "x.png" }
files[picked .. "/x.png"] = { mode = "file", size = 64 }
Assert.eq(Background.folder(), picked)
Background.ensure(background("folder"), function(path) got = path end)
Assert.eq(got, picked .. "/x.png")
settings.lock_screen_folder = nil
Assert.eq(Background.folder(), folder_dir)

Assert.eq(Background.customImage(), screen_dir .. "/custom.png", "没选过用升级前的位置")
settings.lock_screen_custom_image = "/mnt/us/me.jpg"
files["/mnt/us/me.jpg"] = { mode = "file", size = 64 }
Background.ensure(background("custom"), function(path) got = path end)
Assert.eq(got, "/mnt/us/me.jpg")
settings.lock_screen_custom_image = nil

os.date = original_date
