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
    model = "KindleBasic3",
    screen = rex_screen,
}
Waveform.install({ device = rex, text_hist = "gl16" })
Assert.eq(rex_screen._moon_text_hist, "gl16")
settings_on = true
rex_screen.update_data.hist_bw_waveform_mode = "du"
rex_screen.update_data.hist_gray_waveform_mode = "gc16"
rex_screen:mech_refresh(false, "auto")
Assert.eq(seen.bw, "gl16", "Basic 3 的动画刷新走 GL16")

do
    local basic2 = { model = "KindleBasic2", screen = { mech_refresh = function() end } }
    Waveform.install({ device = basic2, text_hist = "gl16" })
    Assert.eq(basic2.screen._moon_text_hist, "gl16", "Basic 2 也装")
end

for _idx, model in ipairs({ "KindlePaperWhite5", "KindlePaperWhite4", "KindleBasic4", "KindleOasis3", "KindleColorsoft" }) do
    local other = { model = model, screen = {} }
    Waveform.install({ device = other, text_hist = "gl16" })
    Assert.is_nil(other.screen._moon_kindle_gray, model .. " 不装钩子")
end

return true
