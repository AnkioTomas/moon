--[[-- utils.rotation：全局旋转记忆与开书注入。 --]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
Stubs.reset()

local saved, flushed = {}, 0
local screen_mode = 0
_G.G_reader_settings = {
    isTrue = function(_, key) return key == "lock_rotation" and saved.lock_rotation == true end,
    readSetting = function(_, key) return saved[key] end,
    saveSetting = function(_, key, value) saved[key] = value; return _G.G_reader_settings end,
    flush = function() flushed = flushed + 1 end,
}
package.preload["device"] = function()
    return {
        screen = {
            getRotationMode = function() return screen_mode end,
            setRotationMode = function(_, mode) screen_mode = mode end,
            DEVICE_ROTATED_UPRIGHT = 0,
        },
    }
end
package.loaded["device"] = nil
package.loaded["utils.rotation"] = nil
package.loaded["utils.extension"] = nil

-- 干净挂点表：只测 rotation 的登记
local Ext = require("utils.extension")
local Rotation = require("utils.rotation")

-- 旋转后写入三键并 flush
do
    saved, flushed, screen_mode = {}, 0, 1
    Rotation.remember(2)
    Assert.eq(saved.fm_rotation_mode, 2)
    Assert.eq(saved.copt_rotation_mode, 2)
    Assert.eq(saved.kopt_rotation_mode, 2)
    Assert.eq(flushed, 1)
end

-- 省略参数时用当前屏幕方向
do
    saved, flushed, screen_mode = {}, 0, 3
    Rotation.remember()
    Assert.eq(saved.fm_rotation_mode, 3)
end

-- 锁定方向时不写
do
    saved, flushed = { lock_rotation = true }, 0
    Rotation.remember(1)
    Assert.is_nil(saved.fm_rotation_mode)
    Assert.eq(flushed, 0)
end

-- 开书注入 sidecar
do
    saved = { fm_rotation_mode = 2 }
    local doc = {}
    function doc:saveSetting(key, value) self[key] = value end
    Rotation.injectDocSettings(doc)
    Assert.eq(doc.copt_rotation_mode, 2)
    Assert.eq(doc.kopt_rotation_mode, 2)
end

-- 无记忆不注入
do
    saved = {}
    local doc = {}
    function doc:saveSetting(key, value) self[key] = value end
    Rotation.injectDocSettings(doc)
    Assert.is_nil(doc.copt_rotation_mode)
end

-- apply：屏幕不一致才扳
do
    saved, screen_mode = { fm_rotation_mode = 1 }, 0
    Rotation.apply()
    Assert.eq(screen_mode, 1)
    Rotation.apply()
    Assert.eq(screen_mode, 1)
end

-- reader.doc_settings 挂点已登记
do
    local found = false
    for _idx, fn in ipairs(Ext.list("reader.doc_settings")) do
        if fn == Rotation.injectDocSettings then found = true end
    end
    Assert.is_true(found, "rotation 须挂 reader.doc_settings")
end
