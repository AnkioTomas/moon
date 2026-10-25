--[[--
wallpaper：经 desktop.backdrop / modal.backdrop 挂点接入；没开不画，hollow 摘掉纯底色层并可还原。
@module tests.features.wallpaper.init_spec
--]]
---@diagnostic disable: missing-fields

local Assert = require("support.assert")
local Stubs = require("support.stubs")

Stubs.install()
local conf = { wallpaper_enabled = true, wallpaper_desktop = true, wallpaper_dialog = true }
package.loaded["utils.settings"] = {
    get = function(owner) assert(owner == "features.wallpaper"); return conf end,
    save = function() end,
}

package.loaded["device"] = { screen = { getWidth = function() return 100 end, getHeight = function() return 100 end } }
package.loaded["utils.image"] = {
    ok = function() return true end,
    suffix = function(name) return name:match("%.png$") end,
}
package.loaded["utils.paths"] = { screensaverDir = function() return "/nonexistent" end }

local Ext = require("utils.extension")
Ext.reset()
package.loaded["features.wallpaper"] = nil
local Wallpaper = require("features.wallpaper")

local desktop = Ext.last("desktop.backdrop")
Assert.is_true(desktop ~= nil)
Assert.is_true(Ext.last("modal.backdrop") ~= nil)

local function tree()
    return { { box_w = 1, style = { bg = 1 } }, { box_w = 1, style = { bg = 1, radius = 4 } } }
end

-- 没选图源：不铺、不摘底色
do
    local page = tree()
    desktop.content(page)
    Assert.is_true(page[1].style.bg == 1)
    Assert.eq(Wallpaper.paintWindow({}, 0, 0, 10, 10, "dialog"), false)
end

-- 选了图源：只摘「只有 bg」的层，带圆角的卡片样式保留；关掉后还原
do
    conf.wallpaper_custom_image = "/tmp/g.png"
    Wallpaper.invalidate()
    local page = tree()
    Assert.is_true(Wallpaper.hollow(page, "desktop"))
    Assert.is_nil(page[1].style.bg)
    Assert.eq(page[2].style.radius, 4)
    conf.wallpaper_enabled = false
    Wallpaper.hollow(page, "desktop")
    Assert.eq(page[1].style.bg, 1)
end

-- 底色就是内容的方块（keep_bg）不摘
do
    conf.wallpaper_custom_image, conf.wallpaper_enabled, conf.wallpaper_desktop = "/tmp/g.png", true, true
    Wallpaper.invalidate()
    local page = { { box_w = 1, style = { bg = 1 }, keep_bg = true }, { box_w = 1, style = { bg = 1 } } }
    Wallpaper.hollow(page, "desktop")
    Assert.eq(page[1].style.bg, 1)
    Assert.is_nil(page[2].style.bg)
end

-- 作用面：没单独存过的界面沿用旧开关；单独关某一页不影响其它页
do
    conf.wallpaper_custom_image, conf.wallpaper_enabled = "/tmp/g.png", true
    conf.wallpaper_desktop, conf.wallpaper_dialog = true, false
    Wallpaper.invalidate()
    Assert.is_true(Wallpaper.enabled("home"))
    Assert.is_true(Wallpaper.enabled("opds"))
    Assert.is_true(not Wallpaper.enabled("settings"))
    conf.wallpaper_settings = false
    conf.wallpaper_dialog = true
    Assert.is_true(not Wallpaper.enabled("settings"))
    Assert.is_true(Wallpaper.enabled("dialog"))
    Wallpaper.setScope("home", false)
    Assert.is_true(not Wallpaper.enabled("home"))
    Assert.is_true(Wallpaper.enabled("library"))
    -- 阅读页默认不开，不沿用旧开关
    Assert.is_true(not Wallpaper.enabled("reader"))
end

-- 专用图：没有全局图时只有设了专用图的界面铺；清除后回到全局
do
    conf.wallpaper_custom_image, conf.wallpaper_home, conf.wallpaper_library = nil, true, true
    Wallpaper.invalidate()
    Assert.is_true(not Wallpaper.enabled("home"))
    Wallpaper.setOverride("home", "image", "/tmp/own.png")
    Assert.is_true(Wallpaper.enabled("home"))
    Assert.is_true(not Wallpaper.enabled("library"))
    Wallpaper.setOverride("home", "image", nil)
    Assert.is_true(not Wallpaper.enabled("home"))
end

-- 铺法与透明度：界面没覆盖就跟全局，覆盖后只影响它自己
do
    Wallpaper.setOpacity(60)
    Assert.eq(Wallpaper.opacity("library"), 60)
    Wallpaper.setOverride("library", "opacity", 30)
    Assert.eq(Wallpaper.opacity("library"), 30)
    Assert.eq(Wallpaper.opacity("home"), 60)
    Wallpaper.setOverride("library", "opacity", nil)
    Assert.eq(Wallpaper.opacity("library"), 60)
end

-- 文件夹壁纸（全局与单个界面都可以是文件夹）：同一轮固定，唤醒后换一张
do
    local dir = os.tmpname()
    os.remove(dir)
    os.execute("mkdir -p " .. dir)
    for _idx, name in ipairs({ "a.png", "b.png", "c.txt" }) do io.open(dir .. "/" .. name, "w"):close() end
    Wallpaper.setImage(dir)
    local first = Wallpaper.path()
    Assert.is_true(first == dir .. "/a.png" or first == dir .. "/b.png")
    Assert.eq(Wallpaper.path(), first, "同一轮固定")
    Wallpaper.onResume()
    Assert.is_true(Wallpaper.path() ~= first, "唤醒后换另一张")
    Wallpaper.setImage("/tmp/g.png")
    Wallpaper.setOverride("library", "image", dir)
    local own = Wallpaper.path("library")
    Assert.is_true(own == dir .. "/a.png" or own == dir .. "/b.png")
    Assert.eq(Wallpaper.path("home"), "/tmp/g.png", "其它界面仍用全局图")
    Wallpaper.setOverride("library", "image", nil)
    os.execute("rm -rf " .. dir)
end
