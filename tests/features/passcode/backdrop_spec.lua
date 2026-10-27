-- features.passcode.backdrop：只在组合锁屏 + 白名单壁纸时给解锁页铺底。

local Assert = require("support.assert")
local Paths = require("utils.paths")
local lfs = require("libs/libkoreader-lfs")

local dir = Paths.screensaverDir()
lfs.mkdir(dir)

local compose = dir .. "/compose.png"
local custom = dir .. "/custom.png"
os.remove(compose)
os.remove(custom)

-- 桩：锁屏设置与 Background.resolve
local conf = { lock_screen = "compose", lock_screen_background = "custom" }
package.preload["utils.settings"] = function()
    return { get = function() return conf end, save = function() end }
end
package.loaded["utils.settings"] = nil

local resolved
package.preload["features.lockscreen.background"] = function()
    return {
        background = function(mode)
            return { id = mode, path = function() return resolved end }
        end,
        resolve = function(asset) return asset.path and asset.path() end,
    }
end
package.loaded["features.lockscreen.background"] = nil
package.loaded["features.passcode.backdrop"] = nil

local Backdrop = require("features.passcode.backdrop")

-- 组合锁屏关：不铺
conf.lock_screen = "ko"
Assert.is_nil(Backdrop.mode())
Assert.is_nil(Backdrop.path())
Assert.is_nil(Backdrop.widget(100, 100))

-- 摸鱼日报 / 统计页 / 无：不铺
conf.lock_screen = "compose"
for _idx, mode in ipairs({ "myrl", "paper", "insight", "typo", "danxiangli", "none" }) do
    conf.lock_screen_background = mode
    Assert.is_nil(Backdrop.mode(), mode)
    Assert.is_nil(Backdrop.path(), mode)
end

-- 自定义：文件在才给路径
conf.lock_screen_background = "custom"
resolved = custom
Assert.eq(Backdrop.mode(), "custom")
Assert.is_nil(Backdrop.path(), "文件不存在")
do
    local f = io.open(custom, "wb")
    Assert.not_nil(f)
    f:write("123456789")
    f:close()
end
Assert.eq(Backdrop.path(), custom)
Assert.not_nil(Backdrop.widget(40, 60))

-- compose.png 即使存在也不用（那是带组件的合成图）
do
    local f = io.open(compose, "wb")
    Assert.not_nil(f)
    f:write("123456789")
    f:close()
end
Assert.eq(Backdrop.path(), custom, "仍走自定义原图，不碰 compose")

-- 必应 / 封面 / 文件夹同属路径白名单
for _idx, mode in ipairs({ "bing", "cover", "folder" }) do
    conf.lock_screen_background = mode
    resolved = custom
    Assert.eq(Backdrop.mode(), mode)
    Assert.eq(Backdrop.path(), custom)
end

-- 海报墙：有模式、无路径，widget 仍能建（自绘）
conf.lock_screen_background = "poster"
Assert.eq(Backdrop.mode(), "poster")
Assert.is_nil(Backdrop.path())
Assert.not_nil(Backdrop.widget(40, 60))

os.remove(custom)
os.remove(compose)
print("passcode backdrop_spec ok")
