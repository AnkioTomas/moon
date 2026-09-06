--[[
    2-swipe-animation-enable.lua

    Force-enable the software swipe animation capability on devices without
    the MTK hardware swipe waveform. The generic framebuffer reports
    canDoSwipeAnimation = no, which would short-circuit
    ReaderView:onPageChangeAnimation before it can request the software effect
    implemented by 2-swipe-animation-core.lua.

    Adapted from Swipe_Animation.koplugin (GPLv3), with its settings-menu
    injection removed in favor of the plugin's own toggle.
]]

local ok, err = pcall(function()
    local Device = require("device")
    Device.canDoSwipeAnimation = function()
        return true
    end
end)

if not ok then
    require("logger").warn("[SwipeAnimationEnablePatch] failed:", err)
end
