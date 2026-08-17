--[[--
lockscreen.styles.myrl：缓存路径 / 按天标记 / 下载落盘

不碰真网络：stub http.request.download 写本地 PNG。

@module tests.lockscreen.styles.myrl_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
local Config = require("support.config")

if not Config.available() then
    io.write("  (skip: config/ 软链不可用)\n")
    return
end

Assert.is_true(Config.setupNativePath())

-- Device.screen 竖屏尺寸
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
    }
end

local Myrl = require("lockscreen.styles.myrl")

local function cleanup()
    pcall(os.remove, Myrl.path())
    pcall(os.remove, Myrl.path() .. ".part")
end

local ok_run, err_run = pcall(function()
    Assert.eq(Myrl.id, "myrl")
    Assert.eq(Myrl.label, "摸鱼日报")
    Assert.is_true(Myrl.path():find("screensaver/myrl%.png$") ~= nil)
    Assert.eq(Myrl.dayKey(), os.date("%Y-%m-%d"))

    -- fetch 成功：tmp 改名落盘
    local done, ok_cb
    local job = Myrl.fetch(function(ok)
        done = true
        ok_cb = ok
    end)
    Assert.not_nil(job)
    Stubs.flush()
    Assert.is_true(done)
    Assert.is_true(ok_cb)
    Assert.is_true(last_download.url:find("api%.ankio%.net/myrl", 1, false) ~= nil)
    Assert.is_true(last_download.url:find("width=480", 1, true) ~= nil)
    Assert.is_true(last_download.url:find("height=800", 1, true) ~= nil)

    local f = assert(io.open(Myrl.path(), "rb"))
    Assert.eq(f:read("*a"), PNG8)
    f:close()
    -- tmp 已改名，不残留
    local lfs = require("libs/libkoreader-lfs")
    Assert.is_nil(lfs.attributes(Myrl.path() .. ".part"))
end)

cleanup()
if not ok_run then
    error(err_run)
end
