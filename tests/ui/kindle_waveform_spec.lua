--[[--
Kindle UI 波形留住字体灰阶：不增加刷新，fast / A2 仍是单色。

@module tests.ui.kindle_waveform_spec
--]]

local Assert = require("support.assert")
local Waveform = require("ui.kindle_waveform")

local settings_on = false
_G.G_reader_settings = {
    isTrue = function(_, key)
        return key == "moon_page_turn_animation" and settings_on
    end,
}

local function fb(fast, a2)
    return {
        waveform_fast = fast,
        waveform_a2 = a2,
        update_data = { hist_bw_waveform_mode = "du", hist_gray_waveform_mode = "gc16" },
    }
end

settings_on = true
local screen_fb = fb("du", "a2")
Waveform.alignHist(screen_fb, "ui")
Assert.eq(screen_fb.update_data.hist_bw_waveform_mode, "gc16", "UI 刷新的笔画跟灰阶走同一条")

screen_fb = fb("du", "a2")
Waveform.alignHist(screen_fb, "du")
Assert.eq(screen_fb.update_data.hist_bw_waveform_mode, "du", "fast/DU 高亮仍压成单色")

screen_fb = fb("du", "a2")
Waveform.alignHist(screen_fb, "a2")
Assert.eq(screen_fb.update_data.hist_bw_waveform_mode, "du", "A2 不动")

screen_fb = fb("du", "a2")
screen_fb.update_data.hist_gray_waveform_mode = 0
Waveform.alignHist(screen_fb, "ui")
Assert.eq(screen_fb.update_data.hist_bw_waveform_mode, "du", "灰阶直方图还没填时不改")

-- mxc_update 上值：只在开了翻页动画时改直方图。
local seen
local function mxc_update(dev, _cmd, data, _flash, mode)
    seen = { bw = data.hist_bw_waveform_mode, mode = mode }
end
local function mech(dev, _flash, mode)
    return mxc_update(dev, nil, dev.update_data, false, mode)
end
local screen = { mech_refresh = mech, update_data = { hist_bw_waveform_mode = "du", hist_gray_waveform_mode = "gc16" }, waveform_fast = "du", waveform_a2 = "a2" }
Assert.is_true(Waveform.hookHist(screen))

settings_on = false
screen.update_data.hist_bw_waveform_mode = "du"
screen:mech_refresh(false, "ui")
Assert.eq(seen.bw, "du", "没开翻页动画不改直方图")

settings_on = true
screen.update_data.hist_bw_waveform_mode = "du"
screen:mech_refresh(false, "ui")
Assert.eq(seen.bw, "gc16")
Assert.eq(seen.mode, "ui", "波形模式仍是原来的 UI，没有多一次刷新")

-- Zelda/Rex：UI 的两条直方图都换成 GL16，正文 partial 仍只对齐、不改模式。
screen.waveform_ui = "auto"
screen._moon_text_hist = "gl16"
screen.update_data.hist_bw_waveform_mode = "du"
screen.update_data.hist_gray_waveform_mode = "gc16"
screen:mech_refresh(false, "auto")
Assert.eq(seen.bw, "gl16", "Rex 的 UI 黑白直方图走 GL16")
Assert.eq(screen.update_data.hist_gray_waveform_mode, "gl16", "抗锯齿灰点也走 GL16，不再留在 GC16")
Assert.eq(seen.mode, "auto", "仍然是 AUTO，不升成阻塞的 REAGL")

screen.update_data.hist_bw_waveform_mode = "du"
screen.update_data.hist_gray_waveform_mode = "glr16"
screen:mech_refresh(false, "partial")
Assert.eq(seen.bw, "glr16", "正文 partial 只对齐直方图")
Assert.eq(screen.update_data.hist_gray_waveform_mode, "glr16", "正文 partial 的灰阶直方图不动")

-- MTK：开了动画时 UI 刷新改走 16 级 partial；关着走原实现。
local waits, modes, origs = 0, {}, 0
local mtk = {
    marker = 0,
    wait_for_submission_before = true,
    dont_wait_for_marker = nil,
    mech_wait_update_submission = function() waits = waits + 1 end,
    mech_refresh = function(_self, _flash, mode) modes[#modes + 1] = mode end,
    refreshUIImp = function() origs = origs + 1 end,
}
Waveform.hookUi(mtk, 10)

settings_on = false
mtk:refreshUIImp(0, 0, 8, 8)
Assert.eq(origs, 1)
Assert.eq(#modes, 0, "没开动画不换波形")

settings_on = true
mtk:refreshUIImp(0, 0, 8, 8)
Assert.eq(modes[1], 10)
Assert.eq(waits, 0, "第一帧 marker 为 0，不等待")

mtk.marker = 4
mtk:refreshUIImp(1, 2, 3, 4)
Assert.eq(waits, 1, "后续帧只等上一帧提交，不等刷完")
Assert.eq(modes[2], 10)

-- 夜间硬件反色：ui 当作 partial 交给 mxc_update（换夜间波形），闪屏不动；翻页动画不再改 MTK 的 UI 刷新。
do
    local night = {
        night_mode = true,
        device = { canHWInvert = function() return true end },
        waveform_ui = "ui",
        waveform_partial = "partial",
        waveform_fast = "du",
        waveform_a2 = "a2",
        update_data = { hist_bw_waveform_mode = "du", hist_gray_waveform_mode = "gc16" },
    }
    night.mech_refresh = function(dev, flash, mode) return mxc_update(dev, nil, dev.update_data, flash, mode) end
    Assert.is_true(Waveform.hookHist(night))
    settings_on = true
    night:mech_refresh(false, "ui")
    Assert.eq(seen.mode, "partial", "夜间 ui 升成 partial")
    Assert.eq(seen.bw, "du", "夜间不改直方图")
    night:mech_refresh(true, "ui")
    Assert.eq(seen.mode, "ui", "闪屏不动")
    night:mech_refresh(false, "du")
    Assert.eq(seen.mode, "du", "fast 不动")
    night.device = { canHWInvert = function() return false end }
    night:mech_refresh(false, "ui")
    Assert.eq(seen.mode, "ui", "软件反色保持原样")

    origs, modes = 0, {}
    local mtk_night = {
        night_mode = true,
        device = { canHWInvert = function() return true end },
        mech_refresh = function(_self, _flash, mode) modes[#modes + 1] = mode end,
        refreshUIImp = function() origs = origs + 1 end,
    }
    Waveform.hookUi(mtk_night, 10)
    mtk_night:refreshUIImp(0, 0, 8, 8)
    Assert.eq(origs, 1, "夜间走原 refreshUIImp")
    Assert.eq(#modes, 0)
end

local installed_mode
local device = {
    screen = {
        mech_refresh = function(_self, _flash, mode) installed_mode = mode end,
        refreshUIImp = function() end,
    },
    _kindle = true,
    _mtk = true,
    isKindle = function(self) return self._kindle end,
    isMTK = function(self) return self._mtk end,
}
package.loaded["logger"] = { warn = function() end }
package.loaded["utils.log"] = { warn = function() end, info = function() end }
Waveform.install({ device = device, ui_waveform = 10 })
Assert.is_true(device.screen._moon_kindle_gray)
Waveform.install({ device = device, ui_waveform = 10 })
settings_on = true
device.screen:refreshUIImp(0, 0, 1, 1)
Assert.eq(installed_mode, 10, "install 后的 UI 刷新走 16 级 partial")

local rex_screen = {
    waveform_ui = "auto",
    waveform_fast = "du",
    waveform_a2 = "a2",
    update_data = { hist_bw_waveform_mode = "du", hist_gray_waveform_mode = "gc16" },
    mech_refresh = function(self, _flash, mode)
        return mxc_update(self, nil, self.update_data, false, mode)
    end,
}
local rex = {
    screen = rex_screen,
    isKindle = function() return true end,
    isMTK = function() return false end,
    isZelda = function() return false end,
    isRex = function() return true end,
}
Waveform.install({ device = rex, text_hist = "gl16" })
Assert.eq(rex_screen._moon_text_hist, "gl16")
settings_on = true
rex_screen.update_data.hist_bw_waveform_mode = "du"
rex_screen.update_data.hist_gray_waveform_mode = "gc16"
rex_screen:mech_refresh(false, "auto")
Assert.eq(seen.bw, "gl16", "Basic 3 这种 Rex 的动画刷新走 GL16")

device._kindle = false
local other = { screen = {}, isKindle = function() return false end, isMTK = function() return true end }
Waveform.install({ device = other, ui_waveform = 10 })
Assert.is_nil(other.screen._moon_kindle_gray, "非 Kindle 不装")

return true
