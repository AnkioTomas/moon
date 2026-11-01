--[[--
Kindle 上把翻页动画的 UI 刷新留在 16 级灰，不改动画、不多刷一次。

阅读器正文走 partial（REAGL）。动画仍用 UI 波形揭开页面。
非 REAGL 刷新把黑白直方图设成 DU。Zelda/Rex（含 Kindle Basic 3）的灰阶直方图
是 GC16：那是闪屏波形，低 dpi 上笔画几乎全是抗锯齿灰点，只把黑白直方图
对齐过去，字还是灰。这种 UI 刷新把两条直方图都改成 GL16（16 级，不阻塞）。
MTK 驱动不看直方图，UI 刷新改走 GC16_PARTIAL。
fast / A2 仍是单色。没开翻页动画时不改任何波形。

@module koplugin.book.ui.kindle_waveform
--]]

local Waveform = {}

--- 与翻页动画开关键相同。下层不引用该 feature，只认这一个已经落盘的设置。
local ENABLED = "moon_page_turn_animation"

---@return boolean
local function pageTurnOn()
    local settings = rawget(_G, "G_reader_settings")
    return settings ~= nil and settings:isTrue(ENABLED) == true
end

--- 非 fast / A2 的刷新：黑白直方图跟灰阶直方图对齐。
--- Zelda/Rex 的 UI（AUTO）另把两条直方图都写成 GL16，灰点不再走 GC16。
---@param fb table
---@param waveform_mode number|nil
---@param ioc_data table|nil 实际送进 ioctl 的结构；缺省用 fb.update_data
function Waveform.alignHist(fb, waveform_mode, ioc_data)
    local data = ioc_data or fb.update_data
    if not data then return end
    if waveform_mode == fb.waveform_fast or waveform_mode == fb.waveform_a2 then return end
    local text = fb._moon_text_hist
    if text and waveform_mode == fb.waveform_ui then
        data.hist_bw_waveform_mode = text
        data.hist_gray_waveform_mode = text
        return
    end
    local gray = data.hist_gray_waveform_mode
    if not gray or gray == 0 then return end
    data.hist_bw_waveform_mode = gray
end

--- 包住 mxcfb 的 mxc_update。找不到这个上值就保持原样。
---@param screen table
---@return boolean
function Waveform.hookHist(screen)
    local refresh = screen.mech_refresh
    if type(refresh) ~= "function" then return false end
    local index = 1
    while true do
        local name, value = debug.getupvalue(refresh, index)
        if not name then return false end
        if name == "mxc_update" and type(value) == "function" then
            local orig = value
            debug.setupvalue(refresh, index, function(fb, ioc_cmd, ioc_data, is_flashing, waveform_mode, ...)
                if pageTurnOn() then
                    Waveform.alignHist(fb, waveform_mode, ioc_data)
                end
                return orig(fb, ioc_cmd, ioc_data, is_flashing, waveform_mode, ...)
            end)
            return true
        end
        index = index + 1
    end
end

--- MTK：UI 刷新改用 16 级 partial 波形。没开翻页动画时仍走原来的 refreshUIImp。
---@param screen table
---@param mode number
function Waveform.hookUi(screen, mode)
    local orig = screen.refreshUIImp
    function screen:refreshUIImp(x, y, w, h, dither)
        if not pageTurnOn() then
            return orig(self, x, y, w, h, dither)
        end
        local marker = self.marker
        if self.wait_for_submission_before and self.mech_wait_update_submission
            and marker and marker ~= 0 and marker ~= self.dont_wait_for_marker then
            self:mech_wait_update_submission(marker)
        end
        return self:mech_refresh(false, mode, x, y, w, h, dither)
    end
end

---@return table|nil
local function kindleC()
    local ok, C = pcall(function()
        require("ffi/mxcfb_kindle_h")
        return require("ffi").C
    end)
    if not ok then return nil end
    return C
end

---@return number|nil
function Waveform.mtkPartialWaveform()
    local C = kindleC()
    if not C then return nil end
    return C.MTK_WAVEFORM_MODE_GC16_PARTIAL
end

--- Zelda/Rex 的 16 级 partial。不是 GC16（闪屏），也不是 GLR16（会被提升成阻塞的 REAGL）。
---@return number|nil
function Waveform.zeldaTextHist()
    local C = kindleC()
    if not C then return nil end
    return C.WAVEFORM_MODE_ZELDA_GL16
end

--- 只在 Kindle 上装。同一块屏幕重复调用无效果。
---@param opts table|nil 测试注入 device / ui_waveform / text_hist；正式调用不传
function Waveform.install(opts)
    opts = opts or {}
    local Device = opts.device or require("device")
    if not Device:isKindle() then return end
    local screen = Device.screen
    if not screen or screen._moon_kindle_gray then return end
    screen._moon_kindle_gray = true
    local log = require("utils.log")
    if not Waveform.hookHist(screen) then
        log.warn("kindle waveform: mxc_update upvalue not found")
    end
    if Device:isMTK() then
        local mode = opts.ui_waveform or Waveform.mtkPartialWaveform()
        if not mode then
            log.warn("kindle waveform: GC16_PARTIAL unavailable")
            return
        end
        Waveform.hookUi(screen, mode)
        log.warn("kindle waveform: mtk GC16_PARTIAL")
        return
    end
    if not (Device:isZelda() or Device:isRex()) then return end
    local text = opts.text_hist or Waveform.zeldaTextHist()
    if not text then
        log.warn("kindle waveform: GL16 unavailable")
        return
    end
    screen._moon_text_hist = text
    log.warn("kindle waveform: zelda GL16 hist")
end

return Waveform
