--[[
    2-swipe-animation-enable.lua

    Force-enable the software swipe animation capability on devices without
    the MTK hardware swipe waveform. The generic framebuffer reports
    canDoSwipeAnimation = no, which would short-circuit
    ReaderView:onPageChangeAnimation before it can request the software effect
    implemented by 2-swipe-animation-core.lua.

    The trigger is gated by Moon's own setting instead of KOReader's native
    "swipe_animations" (MTK hardware animation toggle), so the two never
    interfere.

    Adapted from Swipe_Animation.koplugin (GPLv3), with its settings-menu
    injection removed in favor of the plugin's own toggle.
]]

local ok, err = pcall(function()
    local Device = require("device")
    local ReaderView = require("apps/reader/modules/readerview")
    Device.canDoSwipeAnimation = function()
        return true
    end

    --- 翻页时请求软件动画；开关键须与 patch/page_turn_animation.lua 的 ENABLED_KEY 一致。
    ---@param forward boolean 是否向前翻
    function ReaderView:onPageChangeAnimation(forward)
        if not G_reader_settings:isTrue("moon_page_turn_animation") then return end
        if self.inverse_reading_order then forward = not forward end
        Device.screen:setSwipeAnimations(true)
        Device.screen:setSwipeDirection(forward)
    end
end)

if not ok then
    require("logger").warn("[SwipeAnimationEnablePatch] failed:", err)
end
