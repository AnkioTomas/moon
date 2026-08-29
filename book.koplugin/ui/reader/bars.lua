--[[--
上下进度条（ReaderView view module）。

纯绘制叠加层：叠在 KOReader 原生顶栏 / 底栏之上，背景不透明盖住引擎内容。
几何跟系统状态栏同步；Book 设置项控制 overlay 是否绘制。
底栏 tap/hold 劫持原生 ReaderFooter 手势。

@module koplugin.book.ui.reader.bars
--]]

local Device = require("device")
local Blitbuffer = require("ffi/blitbuffer")
local _ = require("gettext")
local Screen = Device.screen

local HEADER_FONT_SIZE_DEFAULT = 20
--- CRE 页头 HEADER_MARGIN + 亚像素缝，overlay 多盖一点。
local TOP_BAND_BLEED = 9
--- overlay 顶部额外覆盖的像素数（已按屏幕缩放）。
---@return number
local function bandBleed()
    return Screen:scaleBySize(TOP_BAND_BLEED)
end

local Bars = {
    view = nil,
    ui = nil,
    _clock = nil,
    -- paintTo 是 ReaderView 的热路径。缓存文本控件，避免每次局部刷新都重新
    -- 分配 xtext 缓冲和做一次完整排版。
    _paint_widgets = {},
    _paint_widget_keys = {},
}

---@param slot string
---@param key string
---@param opts table
---@return table
local function cachedTextWidget(slot, key, opts)
    local old_key = Bars._paint_widget_keys[slot]
    local widget = Bars._paint_widgets[slot]
    if not widget or old_key ~= key then
        if widget and widget.free then
            widget:free()
        end
        local TextWidget = require("ui/widget/textwidget")
        widget = TextWidget:new(opts)
        Bars._paint_widgets[slot] = widget
        Bars._paint_widget_keys[slot] = key
    end
    return widget
end

local function clearPaintWidgets()
    for slot, widget in pairs(Bars._paint_widgets) do
        if widget and widget.free then
            widget:free()
        end
        Bars._paint_widgets[slot] = nil
        Bars._paint_widget_keys[slot] = nil
    end
end

--- 顶条时间文案。
---@param now number|nil os.time 时间戳（缺省当前）
---@return string
function Bars.timeText(now)
    return os.date("%H:%M", now)
end

--- 当前章节名称：session 目录里的 title。
---@param cur ReaderSessionSnapshot|table|nil
---@param toc BookChapter[]|nil 测试用目录
---@return string
function Bars.chapterTitle(cur, toc)
    if type(cur) ~= "table" then
        return ""
    end
    local snapshot = cur
    if not cur.ui and not cur.chapter and toc then
        snapshot = {
            identity = cur.identity or cur,
            chapter = { toc = toc },
            ui = cur.ui,
        }
    end
    return require("ui.reader.session").chapterTitle(snapshot) or ""
end

--- 剩余阅读时间文案；不足一分钟时为空。
---@param remaining_seconds number|nil
---@return string
function Bars.remainingText(remaining_seconds)
    remaining_seconds = tonumber(remaining_seconds)
    if not remaining_seconds or remaining_seconds < 60 then
        return ""
    end
    local hours = math.floor(remaining_seconds / 3600)
    local minutes = math.floor((remaining_seconds % 3600) / 60)
    if hours > 0 then
        return string.format(_("约 %d 小时 %d 分"), hours, minutes)
    end
    return string.format(_("约 %d 分钟"), minutes)
end

--- 底条进度文案：百分比 · 章号 · 剩余时间（取得到的才拼）。
---@param cur ReaderSessionSnapshot|nil
---@param toc BookChapter[]|nil
---@param remaining_seconds number|nil
---@return string
function Bars.progressText(cur, toc, remaining_seconds)
    if type(cur) ~= "table" then
        return ""
    end
    local parts = {}
    local pct = tonumber(cur.percent) or 0
    if pct < 0 then
        pct = 0
    elseif pct > 100 then
        pct = 100
    end
    parts[#parts + 1] = string.format("%.0f%%", pct)
    local identity = cur.identity
    local idx = tonumber(cur.reading_chapter_idx) or (identity and tonumber(identity.chapter_idx))
    local count = toc and #toc or nil
    if idx and count and count > 0 then
        parts[#parts + 1] = string.format(_("第 %d/%d 章"), idx, count)
    end
    local remaining = Bars.remainingText(remaining_seconds)
    if remaining ~= "" then
        parts[#parts + 1] = remaining
    end
    return table.concat(parts, " · ")
end

--- 设置系统顶栏开/关（同步 configurable + crengine，与 Aa 菜单一致）。
---@param ui table|nil
---@param enabled boolean
---@return nil
function Bars.setSystemTop(ui, enabled)
    ui = ui or Bars.ui
    if not ui or not ui.rolling or not ui.document or not ui.handleEvent then
        return
    end
    if Bars.systemTopVisible(ui) == enabled then
        return
    end
    local config = ui.document.configurable
    if not config then
        return
    end
    local next_val = enabled and 0 or 1
    local Event = require("ui/event")
    ui:handleEvent(Event:new("ConfigChange", "status_line", next_val))
    ui:handleEvent(Event:new("SetStatusLine", next_val))
    if ui.doc_settings and config.saveSettings then
        config:saveSettings(ui.doc_settings, "copt_")
        ui.doc_settings:flush()
    end
end

--- 设置系统底栏开/关（走原生 ReaderFooter 的模式切换）。
--- 目标状态与当前一致时直接返回，避免把 footer 切到别的模式。
---@param ui table|nil ReaderUI 实例，缺省用当前会话的
---@param enabled boolean 是否显示系统底栏
function Bars.setSystemBottom(ui, enabled)
    ui = ui or Bars.ui
    if not ui or Bars.systemBottomVisible(ui) == enabled then
        return
    end
    local footer = ui.view and ui.view.footer
    if footer and footer.onToggleFooterMode then
        footer:onToggleFooterMode()
    end
end

--- 顶栏偏好（未设置时默认开）。
---@return boolean
function Bars.topBarPreference()
    return require("utils.settings").get().book_reader_top_bar ~= false
end

--- 底栏偏好（未设置时默认开）。
---@return boolean
function Bars.bottomBarPreference()
    return require("utils.settings").get().book_reader_bottom_bar ~= false
end

--- 写入顶栏偏好，并在阅读中时立即应用。
---@param enabled boolean
---@param ui table|nil
---@return nil
function Bars.setTopBarPreference(enabled, ui)
    local MoonSettings = require("utils.settings")
    local settings = MoonSettings.get()
    settings.book_reader_top_bar = enabled ~= false
    MoonSettings.save(settings)
    ui = ui or Bars.ui
    if ui then
        Bars.setSystemTop(ui, settings.book_reader_top_bar)
    end
end

--- 写入底栏偏好，并在阅读中时立即应用。
---@param enabled boolean
---@param ui table|nil
---@return nil
function Bars.setBottomBarPreference(enabled, ui)
    local MoonSettings = require("utils.settings")
    local settings = MoonSettings.get()
    settings.book_reader_bottom_bar = enabled ~= false
    MoonSettings.save(settings)
    ui = ui or Bars.ui
    if ui then
        Bars.setSystemBottom(ui, settings.book_reader_bottom_bar)
    end
end

--- 按 Book 设置同步系统顶底栏。
---@param ui table|nil
---@return nil
function Bars.applyPreferences(ui)
    ui = ui or Bars.ui
    if not ui then
        return
    end
    Bars.setSystemTop(ui, Bars.topBarPreference())
    Bars.setSystemBottom(ui, Bars.bottomBarPreference())
end

--- 系统顶栏（CRe Alt Status Bar）是否启用。
---@param ui table|nil
---@return boolean
function Bars.systemTopVisible(ui)
    ui = ui or Bars.ui
    if not ui or not ui.document or not ui.rolling then
        return false
    end
    if ui.view and ui.view.view_mode ~= "page" then
        return false
    end
    return ui.document:getHeaderHeight() > 0
end

--- 系统底栏（ReaderFooter）是否可见。
---@param ui table|nil
---@return boolean
function Bars.systemBottomVisible(ui)
    ui = ui or Bars.ui
    local view = ui and ui.view
    return view and view.footer_visible
end

--- 顶栏 overlay 是否应绘制（= 系统 Alt Status Bar 开）。
---@param ui table|nil
---@return boolean
function Bars.topVisible(ui)
    return Bars.systemTopVisible(ui)
end

--- 底栏 overlay 是否应绘制（= 系统 ReaderFooter 开）。
---@param ui table|nil
---@return boolean
function Bars.bottomVisible(ui)
    return Bars.systemBottomVisible(ui)
end

--- 顶栏 overlay 在 ReaderView paintTo 坐标下的 y / 高度（对齐 CRE 页头绘制位置）。
---@param view table|nil
---@param ui table|nil
---@param paint_y number
---@return number|nil band_y
---@return number|nil band_h
local function topBandGeometry(view, ui, paint_y)
    if not Bars.topVisible(ui) then
        return nil, nil
    end
    ui = ui or Bars.ui
    local header_h = ui.document:getHeaderHeight()
    if not header_h or header_h <= 0 then
        return nil, nil
    end
    local y_off = 0
    if view and view.state and view.state.offset then
        y_off = tonumber(view.state.offset.y) or 0
    end
    if y_off < 0 then
        y_off = 0
    end
  -- 从 ReaderView 顶边铺满到页头下缘，避免 offset 上方与页头底部分缝。
    local band_y = paint_y
    local band_h = y_off + header_h + bandBleed()
    return band_y, band_h
end

--- 底栏 overlay 在 ReaderView paintTo 坐标下的 y / 高度（对齐 BottomContainer 内容区）。
---@param view table|nil
---@param ui table|nil
---@param paint_y number
---@return number|nil band_y
---@return number|nil band_h
local function bottomBandGeometry(view, ui, paint_y)
    if not Bars.bottomVisible(ui) then
        return nil, nil
    end
    ui = ui or Bars.ui
    view = view or Bars.view
    local footer = ui.view and ui.view.footer
    if not footer then
        return nil, nil
    end
    local pos = footer.footer_positioner
    local screen_h = Screen:getHeight()
    local view_h = view and view.dimen and view.dimen.h or screen_h
    if pos and pos.contentRange then
        local range = pos:contentRange()
        local pos_h = pos.dimen and pos.dimen.h or view_h
        local band_h = range.h
        local band_y = paint_y + (pos.dimen and pos.dimen.y or 0) + pos_h - band_h
        local physical_bottom = paint_y + screen_h
        if band_y + band_h < physical_bottom then
            band_h = physical_bottom - band_y
        end
        return band_y, band_h
    end
    local band_h = footer:getHeight()
    if not band_h or band_h <= 0 then
        return nil, nil
    end
    local band_y = paint_y + view_h - band_h
    local physical_bottom = paint_y + screen_h
    if band_y + band_h < physical_bottom then
        band_h = physical_bottom - band_y
    end
    return band_y, band_h
end

--- 顶栏 overlay 相对 paintTo 原点的垂直偏移（CRE 页头随 state.offset 下移）。
---@param ui table|nil
---@return number
function Bars.topOffset(ui)
    if not Bars.topVisible(ui) then
        return 0
    end
    local view = Bars.view or (ui and ui.view)
    if view and view.state and view.state.offset then
        return tonumber(view.state.offset.y) or 0
    end
    return 0
end

--- 系统顶栏高度（像素）；overlay 未启用时为 0。
---@param ui table|nil
---@return number
function Bars.topHeight(ui)
    if not Bars.topVisible(ui) then
        return 0
    end
    ui = ui or Bars.ui
    return ui.document:getHeaderHeight()
end

--- 顶栏水平内边距（左、右），跟文档页边距一致。
---@param ui table|nil
---@return number, number
local function topMargins(ui)
    ui = ui or Bars.ui
    local config = ui and ui.document and ui.document.configurable
    if not config or not config.h_page_margins then
        return 0, 0
    end
    return Screen:scaleBySize(config.h_page_margins[1]),
        Screen:scaleBySize(config.h_page_margins[2])
end

--- 底栏水平内边距（左、右），跟 ReaderFooter 一致。
---@param ui table|nil
---@return number, number
local function bottomMargins(ui)
    ui = ui or Bars.ui
    local footer = ui and ui.view and ui.view.footer
    if not footer then
        return 0, 0
    end
    local margin = footer.horizontal_margin or 0
    local inner = Screen:scaleBySize(footer.settings and footer.settings.progress_margin_width or 0)
    return margin + inner, margin + inner
end

--- 顶栏文字 face：跟 cre_header_status_font_size，不叠 ui_scale；限制在条带高度内。
---@param ui table|nil
---@param bar_h number|nil
---@return table
local function topTextFace(ui, bar_h)
    local Font = require("ui/font")
    local unscaled = G_reader_settings:readSetting(
        "cre_header_status_font_size", HEADER_FONT_SIZE_DEFAULT)
    local scaled = Screen:scaleBySize(unscaled)
    bar_h = tonumber(bar_h) or 0
    if bar_h > 2 and scaled > bar_h - 2 then
        unscaled = math.max(8, math.floor(unscaled * (bar_h - 2) / scaled))
    end
    return Font:getFace("xx_smallinfofont", unscaled)
end

--- 底栏文字 face（跟 ReaderFooter）。
---@param ui table|nil
---@return table
local function bottomTextFace(ui)
    local Font = require("ui/font")
    ui = ui or Bars.ui
    local footer = ui and ui.view and ui.view.footer
    if footer and footer.footer_text_face then
        return footer.footer_text_face
    end
    local settings = footer and footer.settings
    local face_name = settings and settings.text_font_face or "xx_smallinfofont"
    local size = settings and settings.text_font_size or 14
    return Font:getFace(face_name, size)
end

--- 底栏文字颜色（跟 footer_text）。
---@param ui table|nil
---@return any
local function bottomTextColor(ui)
    ui = ui or Bars.ui
    local footer = ui and ui.view and ui.view.footer
    local text = footer and footer.footer_text
    if text and text.fgcolor then
        return text.fgcolor
    end
    return Blitbuffer.COLOR_BLACK
end

--- 不透明背景色（跟 ReaderFooter FrameContainer 一致）。
---@return any
local function barBackground()
    return Blitbuffer.COLOR_WHITE
end

--- 在条带内垂直居中绘制 TextWidget。
---@param widget table
---@param bb any
---@param px number
---@param band_y number
---@param band_h number
local function paintCentered(widget, bb, px, band_y, band_h)
    local sz = widget:getSize()
    widget:paintTo(bb, px, band_y + math.floor((band_h - sz.h) / 2))
end

--- 底栏触摸区（跟 footer 实际高度对齐，fallback 到 DTAP_ZONE_MINIBAR）。
---@param ui table|nil
---@return table
local function footerTouchZone(ui)
    ui = ui or Bars.ui
    local screen_h = Screen:getHeight()
    local view = ui and ui.view
    local band_y, band_h = bottomBandGeometry(view, ui, 0)
    if band_h and band_h > 0 then
        return {
            ratio_x = 0,
            ratio_y = band_y / screen_h,
            ratio_w = 1,
            ratio_h = band_h / screen_h,
        }
    end
    if G_defaults then
        local minib = G_defaults:readSetting("DTAP_ZONE_MINIBAR")
        if minib then
            return {
                ratio_x = minib.x,
                ratio_y = minib.y,
                ratio_w = minib.w,
                ratio_h = minib.h,
            }
        end
    end
    return { ratio_x = 0, ratio_y = 0.9, ratio_w = 1, ratio_h = 0.1 }
end

--- 包装 ReaderFooter：底栏可见时吞掉 tap/hold，禁止切换模式。
---@param ui table
---@return nil
local function hijackFooter(ui)
    local footer = ui.view and ui.view.footer
    if not footer or footer._book_bars_hijacked then
        return
    end
    local orig_tap = footer.TapFooter
    footer.TapFooter = function(self, ges)
        if Bars.systemBottomVisible(self.ui) then
            return true
        end
        return orig_tap(self, ges)
    end
    local orig_hold = footer.onHoldFooter
    footer.onHoldFooter = function(self, ges)
        if Bars.systemBottomVisible(self.ui) then
            return true
        end
        return orig_hold(self, ges)
    end
    footer._book_bars_hijacked = true
end

--- 注册底栏触摸劫持（覆盖 readerfooter_tap / readerfooter_hold）。
---@param ui table
---@return nil
local function registerFooterTouchZones(ui)
    if not ui.registerTouchZones then
        return
    end
    local zone = footerTouchZone(ui)
    ui:registerTouchZones({
        {
            id = "book_bars_footer_tap",
            ges = "tap",
            screen_zone = zone,
            overrides = {
                "readerfooter_tap",
                "readerconfigmenu_ext_tap",
                "readerconfigmenu_tap",
                "tap_forward",
                "tap_backward",
            },
            handler = function()
                if Bars.bottomVisible(ui) then
                    return true
                end
                return false
            end,
        },
        {
            id = "book_bars_footer_hold",
            ges = "hold",
            screen_zone = zone,
            overrides = {
                "readerfooter_hold",
                "readerhighlight_hold",
            },
            handler = function()
                if Bars.bottomVisible(ui) then
                    return true
                end
                return false
            end,
        },
    })
end

--- 安装底栏劫持：ReaderReady 后重注册触摸区（晚于 ReaderFooter）。
---@param ui table
---@return nil
function Bars.install(ui)
    if not ui or ui._book_bars_installed or not Device:isTouchDevice() then
        return
    end
    ui._book_bars_installed = true
    hijackFooter(ui)
    registerFooterTouchZones(ui)
    -- Reader.attach 在 ReaderReady 内执行，postInitCallback 此时已为 nil。
    if ui.registerPostReaderReadyCallback then
        ui:registerPostReaderReadyCallback(function()
            hijackFooter(ui)
            registerFooterTouchZones(ui)
            Bars.applyPreferences(ui)
        end)
    end
    Bars.applyPreferences(ui)
end

--- 每分钟顶条时钟；ReaderUI 销毁后自动停摆。
---@return nil
function Bars:startClock()
    local UIManager = require("ui/uimanager")
    -- Bars 是单例，registerViewModule 每次开书都把 self.ui 覆写成新的 ReaderUI：
    -- 闭包里必须捕获本次的 ui，否则 instance ~= self.ui 永远为假，旧链条不停摆，
    -- 每开一本书就多一条每分钟刷屏的定时器。
    local ui = self.ui
    if self._paint_ui and self._paint_ui ~= ui then
        clearPaintWidgets()
    end
    self._paint_ui = ui
    if self._clock then
        UIManager:unschedule(self._clock)
    end
    --- 刷一次顶条并把自己排到下一个整分；换书或退出阅读后不再续排。
    local function tick()
        if require("apps/reader/readerui").instance ~= ui then
            return
        end
        if Bars.topVisible(ui) and require("ui.reader.session").current() then
            UIManager:setDirty(ui.dialog, "ui")
        end
        UIManager:scheduleIn(61 - tonumber(os.date("%S")), tick)
    end
    self._clock = tick
    UIManager:scheduleIn(61 - tonumber(os.date("%S")), tick)
end

--- 绘制顶条（章节名 + 时间）与底条（进度文案 + 进度条）叠加层。
---@param bb any blitbuffer
---@param x number ReaderView 原点
---@param y number
---@return nil
function Bars:paintTo(bb, x, y)
    local cur = require("ui.reader.session").current()
    if not cur then
        return
    end
    local ui = self.ui
    if not ui then
        return
    end
    local dimen = self.view and self.view.dimen or Screen:getSize()
    local w, h = dimen.w, dimen.h
    local UI = require("ui.components.bookui")
    local Session = require("ui.reader.session")
    local bg = barBackground()

    if Bars.topVisible(ui) then
        local bar_y, bar_h = topBandGeometry(self.view, ui, y)
        if bar_y and bar_h then
            bb:paintRect(x, bar_y, w, bar_h, bg)
            local margin_l, margin_r = topMargins(ui)
            local inner_w = math.max(1, w - margin_l - margin_r)
            local gap = Screen:scaleBySize(4)
            local text_y = bar_y + Bars.topOffset(ui)
            local text_h = Bars.topHeight(ui)
            local face = topTextFace(ui, text_h)

            local time_text = Bars.timeText()
            local time = cachedTextWidget("time",
                table.concat({ time_text, tostring(face), tostring(text_h) }, "\0"), {
                    text = time_text,
                    face = face,
                    fgcolor = Blitbuffer.COLOR_BLACK,
                })
            local ts = time:getSize()
            local title_text = Bars.chapterTitle(Session.current())
            local title_width = math.max(1, inner_w - ts.w - gap)
            local title = cachedTextWidget("title",
                table.concat({ title_text, tostring(face), tostring(title_width), tostring(text_h) }, "\0"), {
                    text = title_text,
                    face = face,
                    fgcolor = Blitbuffer.COLOR_BLACK,
                    max_width = title_width,
                })
            paintCentered(title, bb, x + margin_l, text_y, text_h)
            time:paintTo(bb, x + w - margin_r - ts.w, text_y + math.floor((text_h - ts.h) / 2))
        end
    end

    if Bars.bottomVisible(ui) then
        local footer = ui.view.footer
        local bottom_y, bar_h = bottomBandGeometry(self.view, ui, y)
        if bottom_y and bar_h then
            bb:paintRect(x, bottom_y, w, bar_h, bg)

        local margin_l, margin_r = bottomMargins(ui)
        local inner_w = math.max(1, w - margin_l - margin_r)
        local face = bottomTextFace(ui)
        local fgcolor = bottomTextColor(ui)
        local settings = footer.settings or {}
        local pct = math.max(0, math.min(100, tonumber(cur.percent) or 0))
        local info_text = Bars.progressText(cur, Session.toc(), Session.remainingSeconds())

        local bold = footer.footer_text and footer.footer_text.bold
        local info = cachedTextWidget("info",
            table.concat({ info_text, tostring(face), tostring(fgcolor), tostring(bold) }, "\0"), {
                text = info_text,
                face = face,
                fgcolor = fgcolor,
                bold = bold,
            })

        if settings.disable_progress_bar then
            info.max_width = inner_w
            paintCentered(info, bb, x + margin_l, bottom_y, bar_h)
        elseif settings.progress_bar_position == "above" then
            local prog_h = footer.progress_bar and footer.progress_bar.height or UI.sz(6)
            local prog_w = math.max(1, inner_w)
            local gap = Screen:scaleBySize(4)
            local info_h = info:getSize().h
            local stack_h = prog_h + gap + info_h
            local stack_y = bottom_y + math.floor((bar_h - stack_h) / 2)
            local bar = UI.progressBar(prog_w, prog_h, pct)
            bar:paintTo(bb, x + margin_l, stack_y)
            bar:free()
            info.max_width = inner_w
            info:paintTo(bb, x + margin_l, stack_y + prog_h + gap)
        elseif settings.progress_bar_position == "below" then
            local prog_h = footer.progress_bar and footer.progress_bar.height or UI.sz(6)
            local prog_w = math.max(1, inner_w)
            local gap = Screen:scaleBySize(4)
            info.max_width = inner_w
            local info_h = info:getSize().h
            local stack_h = info_h + gap + prog_h
            local stack_y = bottom_y + math.floor((bar_h - stack_h) / 2)
            info:paintTo(bb, x + margin_l, stack_y)
            local bar = UI.progressBar(prog_w, prog_h, pct)
            bar:paintTo(bb, x + margin_l, stack_y + info_h + gap)
            bar:free()
        else
            -- 跟 ReaderFooter alongside：文字优先占满，进度条用剩余宽度（至少 min_width_pct）。
            local gap = Screen:scaleBySize(8)
            local min_bar_pct = tonumber(settings.progress_bar_min_width_pct) or 20
            local prog_h = footer.progress_bar and footer.progress_bar.height or UI.sz(6)
            local prog_w
            if settings.progress_bar_lock_width then
                prog_w = math.max(1, math.floor(min_bar_pct / 100 * inner_w))
                info.max_width = math.max(1, inner_w - prog_w - gap)
            else
                local text_max_ratio = (100 - min_bar_pct) / 100
                info.max_width = math.max(1, math.floor(text_max_ratio * inner_w))
                local is = info:getSize()
                prog_w = math.max(1, inner_w - is.w - gap)
            end
            local is = info:getSize()
            local row_h = math.max(is.h, prog_h)
            local row_y = bottom_y + math.floor((bar_h - row_h) / 2)
            local bar = UI.progressBar(prog_w, prog_h, pct)
            bar:paintTo(bb, x + margin_l, row_y + math.floor((row_h - prog_h) / 2))
            bar:free()
            info:paintTo(bb, x + margin_l + prog_w + gap, row_y + math.floor((row_h - is.h) / 2))
        end
        end
    end
end

return Bars
