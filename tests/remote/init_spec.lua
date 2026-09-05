--[[-- remote.init：文件管理布局公开锁屏壁纸，但不泄露 .moon 配置。 --]]

local Assert = require("support.assert")
local Config = require("support.config")

local data = Config.dir() .. "/remote-layout/data"
local book = Config.dir() .. "/remote-layout/books"
local dirs = {
    [data] = true,
    [book] = true,
}
local files = {}

package.preload["datastorage"] = function()
    return {
        getDataDir = function() return data end,
        getFullDataDir = function() return data end,
    }
end
package.preload["ffi/util"] = function()
    return {
        realpath = function(path)
            return path ~= "" and path or nil
        end,
        dirname = function(path)
            return path:match("(.+)/[^/]+$") or "/"
        end,
        basename = function(path)
            return path:match("([^/]+)$") or path
        end,
    }
end
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path, key)
            local attr
            if dirs[path] then
                attr = { mode = "directory" }
            elseif files[path] then
                attr = { mode = "file", size = 1 }
            end
            return key and attr and attr[key] or attr
        end,
        mkdir = function(path)
            dirs[path] = true
            return true
        end,
    }
end
package.preload["utils.settings"] = function()
    return {
        get = function() return { remote_port = 9528 } end,
        getSource = function() return { path = book } end,
    }
end
package.preload["utils.log"] = function()
    return { info = function() end, warn = function() end }
end
package.preload["gettext"] = function()
    return function(text) return text end
end
package.preload["device"] = function()
    return {
        hasClipboard = function() return false end,
        isKindle = function() return false end,
    }
end
package.preload["ui/uimanager"] = function()
    return {
        insertZMQ = function() end,
        removeZMQ = function() end,
    }
end

local server_opts
package.preload["remote.server"] = function()
    return {
        new = function(opts)
            server_opts = opts
            return {
                start = function() return true end,
                stop = function() end,
            }
        end,
    }
end

G_reader_settings = {
    readSetting = function() return nil end,
}

package.loaded["remote.init"] = nil
package.loaded["utils.paths"] = nil
local Remote = require("remote.init")
Assert.is_true(Remote.start())

local wallpapers = data .. "/.moon/screensaver"
Assert.is_true(dirs[wallpapers], "启动远程管理时应创建锁屏壁纸目录")

local shortcut
for _, item in ipairs(server_opts.shortcuts) do
    if item.label == "锁屏壁纸" then
        shortcut = item
        break
    end
end
Assert.eq(shortcut and shortcut.path, wallpapers)

local wallpaper = wallpapers .. "/cover.png"
files[wallpaper] = true
Assert.eq(server_opts.handlers.resolve_download(wallpaper), wallpaper)

local secret = data .. "/.moon/settings/moon.lua"
files[secret] = true
Assert.is_nil(server_opts.handlers.resolve_download(secret))

Remote.stop()

return true
