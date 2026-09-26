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
--- 软链表：前缀 → 真实目标，realpath 按最长前缀替换。
local links = {}

package.preload["datastorage"] = function()
    return {
        getDataDir = function() return data end,
        getFullDataDir = function() return data end,
    }
end
package.preload["ffi/util"] = function()
    return {
        realpath = function(path)
            if path == "" then return nil end
            for link, target in pairs(links) do
                if path == link or path:sub(1, #link + 1) == link .. "/" then
                    return target .. path:sub(#link + 1)
                end
            end
            return path
        end,
        dirname = function(path)
            return path:match("(.+)/[^/]+$") or "/"
        end,
        basename = function(path)
            return path:match("([^/]+)$") or path
        end,
    }
end
local function attributes(path, key)
    local attr
    if dirs[path] then
        attr = { mode = "directory" }
    elseif files[path] then
        attr = { mode = "file", size = 1 }
    end
    return key and attr and attr[key] or attr
end
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = attributes,
        symlinkattributes = function(path, key)
            if links[path] then
                return key and "link" or { mode = "link" }
            end
            return attributes(path, key)
        end,
        mkdir = function(path)
            dirs[path] = true
            return true
        end,
    }
end
package.preload["utils.settings"] = function()
    return {
        get = function() return { remote_port = 9528, remote_idle_stop = true } end,
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

-- 空闲自动关闭开启时，把超时与停服回调交给 server。
Assert.is_true(Remote.idleStopOn())
Assert.eq(server_opts.idle_timeout, Remote.IDLE_STOP)
Assert.eq(server_opts.on_idle, Remote.stop)

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
Assert.eq(server_opts.handlers.resolve_download(secret), secret)

-- 跨设备上传：读错或刷盘失败不能将临时文件改名成正式文件。
package.preload["workers.job"] = function()
    return {
        run = function(work, opts)
            assert(type(opts.name) == "string" and opts.name ~= "", "workers.job.run: opts.name required")
            assert(({ instant = true, light = true, medium = true, heavy = true })[opts.kind],
                "workers.job.run: kind must be instant|light|medium|heavy")
            opts.on_done(work())
            return { cancel = function() end }
        end,
    }
end
package.loaded["workers.job"] = nil

-- 删除要和改名一样挡住配置/凭证；公开壁纸目录照常可删。
do
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

-- .moon 软链到书籍根内（如外置卡）：realpath 后的凭证路径仍须挡删除。
Remote.stop()
links[data .. "/.moon"] = book .. "/moon-sd"
dirs[book .. "/moon-sd"] = true
files[book .. "/moon-sd/settings/moon.lua"] = true
Assert.is_true(Remote.start())
do
    local delete_err
    server_opts.handlers.delete(book .. "/moon-sd/settings/moon.lua", function(_, err) delete_err = err end)
    Assert.eq(delete_err, "protected path")
end
links = {}

-- 软链接只操作链接本身：删除/改名不能落到链接指向的书上，指向范围外的链接也能删。
do
    local target = book .. "/shelf/precious.epub"
    local link = book .. "/link.epub"
    dirs[book .. "/shelf"] = true
    files[target] = true
    local original_remove = os.remove
    for _, dest in ipairs({ target, "/outside/secret.epub" }) do
        links[link] = dest
        local removed, ok, err
        os.remove = function(path) removed = path; return true end
        server_opts.handlers.delete(link, function(a, b) ok, err = a, b end)
        os.remove = original_remove
        Assert.is_true(ok, err)
        Assert.eq(removed, link)
    end

    links[link] = target
    local from, to, ok, err
    os.rename = function(a, b) from, to = a, b; return true end
    server_opts.handlers.rename(link, book .. "/renamed.epub", function(a, b) ok, err = a, b end)
    os.rename = original_rename
    Assert.is_true(ok, err)
    Assert.eq(from, link)
    Assert.eq(to, book .. "/renamed.epub")

    local escaped
    server_opts.handlers.delete(book .. "/shelf/..", function(_, e) escaped = e end)
    Assert.eq(escaped, "path outside managed roots")
    links = {}
end

Remote.stop()

return true
