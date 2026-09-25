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
local moon_shortcut
for _, item in ipairs(server_opts.shortcuts) do
    if item.label == "锁屏壁纸" then
        shortcut = item
    elseif item.label == "月读数据目录" then
        moon_shortcut = item
    end
end
Assert.eq(shortcut and shortcut.path, wallpapers)
Assert.eq(moon_shortcut and moon_shortcut.path, data .. "/.moon")

local wallpaper = wallpapers .. "/cover.png"
files[wallpaper] = true
Assert.eq(server_opts.handlers.resolve_download(wallpaper), wallpaper)

local secret = data .. "/.moon/settings/moon.lua"
files[secret] = true
Assert.is_nil(server_opts.handlers.resolve_download(secret))

-- 跨设备上传：读错或刷盘失败不能将临时文件改名成正式文件。
package.preload["workers.job"] = function()
    return {
        run = function(work, opts)
            opts.on_done(work())
            return { cancel = function() end }
        end,
    }
end
package.loaded["workers.job"] = nil

-- 覆盖上传与删除要和改名、下载一样挡住配置/凭证；公开壁纸目录照常可删。
do
    dirs[data .. "/.moon/settings"] = true
    files[data .. "/settings.reader.lua"] = true
    local cases = {
        { data, "settings.reader.lua" },
        { data .. "/.moon/settings", "moon.lua" },
    }
    for _, case in ipairs(cases) do
        local result, reason
        server_opts.handlers.save("upload.tmp", case[1], case[2], function(ok, err)
            result, reason = ok, err
        end, "overwrite")
        Assert.is_nil(result)
        Assert.eq(reason, "protected path")
    end

    local deleted, delete_err
    server_opts.handlers.delete(secret, function(ok, err) deleted, delete_err = ok, err end)
    Assert.is_nil(deleted)
    Assert.eq(delete_err, "protected path")

    server_opts.handlers.delete(wallpaper, function(_, err) delete_err = err end)
    Assert.is_true(delete_err ~= "protected path", "公开壁纸不属于凭证路径")
end

local original_open, original_rename = io.open, os.rename
local failure_mode, published, rename_calls, read_calls
io.open = function(path, mode)
    if mode == "rb" then
        return {
            read = function()
                if failure_mode == "read" then return nil, "read failed" end
                read_calls = read_calls + 1
                if read_calls == 1 then return "book data" end
                return nil
            end,
            close = function() return true end,
        }
    end
    Assert.matches(path, "moon%-upload")
    return {
        write = function()
            if failure_mode == "write" then return nil, "write failed" end
            return true
        end,
        close = function()
            if failure_mode == "close" then return nil, "flush failed" end
            return true
        end,
    }
end
os.rename = function(_, target)
    rename_calls = rename_calls + 1
    if rename_calls > 1 and target == book .. "/upload.epub" then
        published = true
        return true
    end
    return nil, "cross-device"
end

for _, mode in ipairs({ "read", "write", "close" }) do
    failure_mode, published, rename_calls, read_calls = mode, false, 0, 0
    local result, reason
    server_opts.handlers.save("upload.tmp", book, "upload.epub", function(ok, err)
        result, reason = ok, err
    end)
    Assert.is_nil(result)
    Assert.matches(reason, mode == "close" and "flush failed" or mode .. " failed")
    Assert.is_false(published)
end

failure_mode, published, rename_calls, read_calls = nil, false, 0, 0
local saved, save_err
server_opts.handlers.save("upload.tmp", book, "upload.epub", function(ok, err)
    saved, save_err = ok, err
end)
Assert.is_true(saved)
Assert.is_nil(save_err)
Assert.is_true(published)
io.open, os.rename = original_open, original_rename

Remote.stop()

return true
