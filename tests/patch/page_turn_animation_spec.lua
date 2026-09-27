--[[--
翻页动画：首次开启时把全刷间隔设为从不，之后允许用户自行修改。

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
Assert.is_true(store.moon_page_turn_animation)
Assert.is_nil(store.swipe_animations, "不碰 KOReader 原生开关")

PageTurnAnimation.checkStartup()
local UIManager = require("ui/uimanager")
UIManager:setRefreshRate(6, 1)
Assert.eq(last_rate.day, 6, "开启动画后仍允许改刷新率")
Assert.eq(last_rate.night, 1)

Assert.is_true(PageTurnAnimation.setEnabled(false).ok)
Assert.eq(store.full_refresh_count, 6)
Assert.eq(store.night_full_refresh_count, 6)
Assert.is_nil(store.swipe_animations_prev_refresh_rate)
Assert.eq(store.moon_page_turn_animation, false)
Assert.is_nil(store.swipe_animations)

-- 再次开启只在没有备份时执行；用户自行改回的值不被重复覆盖。
store.full_refresh_count = 6
store.night_full_refresh_count = 6
Assert.is_true(PageTurnAnimation.setEnabled(true).ok)
Assert.eq(store.full_refresh_count, 0)
Assert.eq(store.night_full_refresh_count, 0)
store.full_refresh_count = 3
store.night_full_refresh_count = 1
Assert.is_true(PageTurnAnimation.setEnabled(false).ok)
Assert.eq(store.full_refresh_count, 3)
Assert.eq(store.night_full_refresh_count, 1)

-- 兼容旧版本遗留备份：用户手动改过的一侧不能被关闭动画覆盖。
store.swipe_animations_prev_refresh_rate = { day = 6, night = 6 }
store.full_refresh_count = 3
store.night_full_refresh_count = 0
Assert.is_true(PageTurnAnimation.setEnabled(false).ok)
Assert.eq(store.full_refresh_count, 3)
Assert.eq(store.night_full_refresh_count, 6)

-- 风格：未设置 / 已下线的值回退擦除；选择器落设置并只在真正改变时回调。
local popup_opts
package.loaded["ui.views.popup"] = { list = function(opts) popup_opts = opts end }
Assert.eq(PageTurnAnimation.currentStyle().value, "wipe")
store.swipe_animation_style = "cover"
Assert.eq(PageTurnAnimation.currentStyle().value, "wipe")
store.swipe_animation_style = "box"
Assert.eq(PageTurnAnimation.currentStyle().text, "方框")

local changes = 0
PageTurnAnimation.pickStyle(function() changes = changes + 1 end)
Assert.eq(popup_opts.current, "box")
Assert.eq(popup_opts.items, PageTurnAnimation.STYLES)
popup_opts.on_select("box")
Assert.eq(changes, 0, "选了当前值不算改变")
popup_opts.on_select("split")
Assert.eq(store.swipe_animation_style, "split")
Assert.eq(changes, 1)
PageTurnAnimation.pickStyle()
popup_opts.on_select("wipe")
Assert.eq(store.swipe_animation_style, "wipe", "无回调也能落设置")

-- 启动自检：已安装但运行时补丁内容变了（插件升级）时重新分发并提示重启；没变则静默。
local shown = {}
UIManager.show = function(_, widget) shown[#shown + 1] = widget end
local Manager = require("patch.manager")
local function reload()
    package.loaded["patch.page_turn_animation"] = nil
    return require("patch.page_turn_animation")
end

--- state: 启动前的设置快照（整表替换相关键）；applied: 补丁是否在位。
local function startup(install_res, applied, state)
    Manager.install = function() return install_res end
    Manager.isApplied = function() return applied ~= false end
    shown = {}
    state = state or { moon_page_turn_animation = true }
    for _, key in ipairs({ "moon_page_turn_animation", "swipe_animations", "swipe_animations_prev_refresh_rate" }) do
        store[key] = state[key]
    end
    reload().checkStartup()
end

-- 只开了 KOReader 原生动画（MTK Kindle 硬件动画），Moon 从未开过：不迁移、不追问。
startup({ ok = true }, false, { swipe_animations = true })
Assert.len(shown, 0)
Assert.is_nil(store.moon_page_turn_animation)

-- 旧版 Moon 用户（原生键 + 刷新率备份）：迁移到 Moon 键；补丁被升级覆盖时追问。
startup({ ok = true }, false, {
    swipe_animations = true, swipe_animations_prev_refresh_rate = { day = 6, night = 6 },
})
Assert.is_true(store.moon_page_turn_animation)
Assert.len(shown, 1)
Assert.eq(shown[1].text, "翻页动画补丁已失效（可能因 KOReader 升级）。是否重新安装？")
Assert.is_false(shown[1].dismissable)

-- 取消即关闭 Moon 动画、交还刷新率；原生开关不动；下次启动不再追问。
store.full_refresh_count = 0
shown[1].cancel_callback()
Assert.eq(store.moon_page_turn_animation, false)
Assert.is_nil(store.swipe_animations_prev_refresh_rate)
Assert.eq(store.full_refresh_count, 6)
Assert.is_true(store.swipe_animations)
shown = {}
reload().checkStartup()
Assert.len(shown, 0)

-- 旧版更早的用户（没有刷新率备份，但补丁在位）：同样迁移，并补上刷新率备份。
startup({ ok = true, changed = false }, true, { swipe_animations = true })
Assert.is_true(store.moon_page_turn_animation)
Assert.len(shown, 0)
Assert.not_nil(store.swipe_animations_prev_refresh_rate)

-- Moon 键已显式关闭：即使原生键开着也不迁移。
startup({ ok = true }, true, { moon_page_turn_animation = false, swipe_animations = true })
Assert.eq(store.moon_page_turn_animation, false)
Assert.len(shown, 0)

startup({ ok = true, changed = false })
Assert.len(shown, 0)

startup({ ok = true, changed = true })
Assert.len(shown, 1)
Assert.eq(shown[1].text, "翻页动画补丁已更新，需重启 KOReader 生效。")

startup({ ok = false, err = "disk full" })
Assert.len(shown, 1)
Assert.matches(shown[1].text, "disk full")

return true
