--[[--
翻页动画：开启时默认把全刷改成从不，但不拦截用户再改。

@module tests.patch.page_turn_animation_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")

Stubs.install()
Stubs.reset()

local store = {}
_G.G_reader_settings = {
    isTrue = function(_, key) return store[key] == true end,
    has = function(_, key) return store[key] ~= nil end,
    readSetting = function(_, key) return store[key] end,
    saveSetting = function(_, key, value) store[key] = value end,
    delSetting = function(_, key) store[key] = nil end,
}

local last_rate
package.loaded["ui/uimanager"] = nil
package.preload["ui/uimanager"] = function()
    return {
        setRefreshRate = function(_, rate, night_rate)
            last_rate = { day = rate, night = night_rate }
        end,
        show = function() end,
        close = function() end,
        restartKOReader = function() end,
    }
end
package.preload["ui/widget/confirmbox"] = function()
    return { new = function(_, o) return o end }
end
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_, o) return o end }
end
package.preload["patch.manager"] = function()
    return {
        isApplied = function() return true end,
        install = function() return { ok = true } end,
        restore = function() return { ok = true } end,
    }
end

package.loaded["patch.page_turn_animation"] = nil
local PageTurnAnimation = require("patch.page_turn_animation")

store.full_refresh_count = 6
store.night_full_refresh_count = 6

Assert.is_true(PageTurnAnimation.setEnabled(true).ok)
Assert.eq(store.full_refresh_count, 0)
Assert.eq(store.night_full_refresh_count, 0)
Assert.eq(store.swipe_animations_prev_refresh_rate.day, 6)
Assert.eq(store.swipe_animations_prev_refresh_rate.night, 6)
Assert.is_true(store.swipe_animations)

PageTurnAnimation.checkStartup()
local UIManager = require("ui/uimanager")
UIManager:setRefreshRate(6, 1)
Assert.eq(last_rate.day, 6, "开启动画后仍允许改刷新率")
Assert.eq(last_rate.night, 1)

Assert.is_true(PageTurnAnimation.setEnabled(false).ok)
Assert.eq(store.full_refresh_count, 6)
Assert.eq(store.night_full_refresh_count, 6)
Assert.is_nil(store.swipe_animations_prev_refresh_rate)
Assert.eq(store.swipe_animations, false)

return true
