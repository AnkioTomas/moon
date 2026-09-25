--[[--
上下进度条（ReaderView view module）。

纯绘制叠加层：叠在 KOReader 原生顶栏 / 底栏之上，背景不透明盖住引擎内容。
几何跟系统状态栏同步；开启跟随系统，替代开关决定要不要盖住原栏。
底栏短按透传给原生翻页区，长按只用于阻止 ReaderFooter 切换模式。

@module koplugin.book.ui.reader.bars
--]]

local Device = require("device")
local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local Layout = require("ui.reader.bars.layout")
local _ = require("gettext")
local Screen = Device.screen

local HEADER_FONT_SIZE_DEFAULT = 20
--- 比 CRE 原生页头额外增加的固定高度，不跟文档页边距变化。
local TOP_BAR_EXTRA_HEIGHT = 12
--- 顶栏固定水平留白，不跟书籍左右页边距变化。
local TOP_BAR_HORIZONTAL_PADDING = 12
--- 底栏文字向屏幕内侧偏移，避免视觉上贴住边缘。
local BOTTOM_CONTENT_INSET = 4
--- 顶栏额外高度（已按屏幕缩放）。
---@return number
local function topBarExtraHeight()
    return Screen:scaleBySize(TOP_BAR_EXTRA_HEIGHT)
end

---@class BookReaderBars
---@field view table|nil
---@field ui table|nil
---@field _clock fun()|nil
---@field _paint_widgets table
---@field _paint_widget_keys table
local Bars = {
    view = nil,
    ui = nil,
    _clock = nil,
    -- paintTo 是 ReaderView 的热路径。缓存文本控件，避免每次局部刷新都重新
    -- 分配 xtext 缓冲和做一次完整排版。
    _paint_widgets = {},
    _paint_widget_keys = {},
}

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
    local text = os.date("%H:%M", now)
    ---@cast text string
    return text
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

--- 设置系统顶栏开/关（同步 configurable + crengine，与 Aa 菜单一致）。
---@param ui table|nil
---@param enabled boolean
function Bars.setSystemTop(ui, enabled)
    ui = ui or Bars.ui
    if not ui or not ui.rolling or not ui.document or not ui.handleEvent then
        return
    end
    local config = ui.document.configurable
    if not config then
        return
    end
    local next_val = enabled and 0 or 1
    if tonumber(config.status_line) == next_val then
        return
    end
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
    if not ui or Bars.bottomVisible(ui) == enabled then
        return
    end
    local footer = ui.view and ui.view.footer
    if not footer or not footer.applyFooterMode then
        return
    end
    local mode
    if enabled then
        mode = footer._book_bars_mode
            or (footer.mode_list and footer.mode_list.page_progress)
    else
        footer._book_bars_mode = footer.mode
        mode = footer.mode_list and footer.mode_list.off
    end
    if mode == nil then
        return
    end
    footer:applyFooterMode(mode)
    if G_reader_settings then
        G_reader_settings:saveSetting("reader_footer_mode", mode)
    end
    if footer.onUpdateFooter then
        footer:onUpdateFooter(true)
    end
    if footer.rescheduleFooterAutoRefreshIfNeeded then
        footer:rescheduleFooterAutoRefreshIfNeeded()
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
function Bars.applyPreferences(ui)
    ui = ui or Bars.ui
    if not ui then
        return
    end
    Bars.setSystemTop(ui, Bars.topBarPreference())
    Bars.setSystemBottom(ui, Bars.bottomBarPreference())
end

--- 顶栏 overlay 是否应绘制（系统 Alt Status Bar 开）。
---@param ui table|nil
---@return boolean
function Bars.topVisible(ui)
    ui = ui or Bars.ui
    if not ui or not ui.document or not ui.rolling then
        return false
    end
    if ui.view and ui.view.view_mode ~= "page" then
        return false
    end
    return ui.document:getHeaderHeight() > 0
end

--- 底栏 overlay 是否应绘制（系统 ReaderFooter 开）。
---@param ui table|nil
---@return boolean|nil
function Bars.bottomVisible(ui)
    ui = ui or Bars.ui
    local view = ui and ui.view
    return view and view.footer_visible
end

--- 底栏 overlay 在 ReaderView paintTo 坐标下的 y / 高度（对齐 BottomContainer 内容区）。
--- 背景向下补到物理屏底。
---@param view table ReaderView
---@param footer table ReaderFooter
---@param paint_y number
---@return number|nil band_y
---@return number|nil band_h
local function bottomBandGeometry(view, footer, paint_y)
    local pos = footer.footer_positioner
    local screen_h = Screen:getHeight()
    local view_h = view.dimen and view.dimen.h or screen_h
    local band_y, band_h
    if pos and pos.contentRange then
        band_h = pos:contentRange().h
        band_y = paint_y + (pos.dimen and pos.dimen.y or 0) + (pos.dimen and pos.dimen.h or view_h) - band_h
    else
        band_h = footer:getHeight()
        if not band_h or band_h <= 0 then
            return nil, nil
        end
        band_y = paint_y + view_h - band_h
    end
    return band_y, math.max(band_h, paint_y + screen_h - band_y)
end

--- 顶栏固定水平内边距（左、右）。
---@return number, number
local function topMargins()
    local margin = Screen:scaleBySize(TOP_BAR_HORIZONTAL_PADDING)
    return margin, margin
end

--- 底栏水平内边距（左、右），跟 ReaderFooter 一致。
---@param footer table ReaderFooter
---@return number, number
local function bottomMargins(footer)
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

--- 包装 ReaderFooter：底栏可见时禁止切换模式；短按继续交给原生翻页区，
--- 兼容把蓝牙按钮转换为屏幕点击的翻页器。
---@param ui table
local function hijackFooter(ui)
    local footer = ui.view and ui.view.footer
    if not footer or footer._book_bars_hijacked then
        return
    end
    local orig_tap = footer.TapFooter
    footer.TapFooter = function(self, ges)
        if Bars.bottomVisible(self.ui) and Layout.replace("bottom") then
            return false
        end
        return orig_tap(self, ges)
    end
    local orig_hold = footer.onHoldFooter
    footer.onHoldFooter = function(self, ges)
        if Bars.bottomVisible(self.ui) and Layout.replace("bottom") then
            return true
        end
        return orig_hold(self, ges)
    end
    footer._book_bars_hijacked = true
end

--- 安装底栏模式保护。
---@param ui table
function Bars.install(ui)
    if not ui or ui._book_bars_installed or not Device:isTouchDevice() then
        return
    end
    ui._book_bars_installed = true
    hijackFooter(ui)
    -- Reader.onCreate 在 ReaderReady 内执行，postInitCallback 此时已为 nil。
    if ui.registerPostReaderReadyCallback then
        ui:registerPostReaderReadyCallback(function()
            hijackFooter(ui)
            Bars.applyPreferences(ui)
        end)
    end
    Bars.applyPreferences(ui)
end

--- 每分钟顶条时钟；ReaderUI 销毁后自动停摆。
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
        if Bars.topVisible(ui) and Layout.replace("top") and require("ui.reader.session").current() then
            UIManager:setDirty(ui.dialog, "ui", Geom:new{
                x = 0,
                y = 0,
                w = ui.view.dimen.w,
                h = ui.document:getHeaderHeight() + topBarExtraHeight(),
            })
        end
        UIManager:scheduleIn(61 - tonumber(os.date("%S")), tick)
    end
    self._clock = tick
    UIManager:scheduleIn(61 - tonumber(os.date("%S")), tick)
end

--- 当前阅读会话给栏组件用的上下文。
---@return table|nil
local function liveContext()
    local Session = require("ui.reader.session")
    local cur = Session.current()
    if not cur then
        return nil
    end
    local identity = cur.identity or {}
    local book = identity.book or {}
    local toc = Session.toc()
    return {
        chapter = Session.chapterTitle(cur) or "",
        title = book.title or "",
        clock = Bars.timeText(),
        percent = cur.percent,
        chapter_idx = tonumber(cur.reading_chapter_idx) or tonumber(identity.chapter_idx),
        chapter_count = toc and #toc or nil,
        page = cur.page,
        total_pages = cur.total_pages,
        remaining = Bars.remainingText(Session.remainingSeconds()),
    }
end

--- 绘制顶条 / 底条叠加层；替代开关关掉时不画，露出系统原栏。
---@param bb any blitbuffer
---@param x number ReaderView 原点
---@param y number
function Bars:paintTo(bb, x, y)
    local ctx = liveContext()
    if not ctx then
        return
    end
    local ui = self.ui
    local dimen = self.view and self.view.dimen or Screen:getSize()
    local w = dimen.w
    local Items = require("ui.reader.bars.items")
    local bg = Blitbuffer.COLOR_WHITE
    local cache = { widgets = Bars._paint_widgets, keys = Bars._paint_widget_keys }

    if Bars.topVisible(ui) and Layout.replace("top") then
        -- ReaderView.state.offset 属于文档可视区，不是状态栏几何，不能混进来。
        local header_h = ui.document:getHeaderHeight()
        local bar_h = header_h + topBarExtraHeight()
        bb:paintRect(x, y, w, bar_h, bg)
        local margin_l, margin_r = topMargins()
        Items.paint(
            bb, x + margin_l, y, math.max(1, w - margin_l - margin_r), bar_h,
            Layout.get("top"), ctx, {
                face = topTextFace(ui, header_h),
                fgcolor = Blitbuffer.COLOR_BLACK,
                cache = cache,
                prefix = "top:",
            }
        )
    end

    if Bars.bottomVisible(ui) and Layout.replace("bottom") then
        local footer = ui.view.footer
        local bottom_y, bar_h = bottomBandGeometry(self.view, footer, y)
        if bottom_y and bar_h then
            local bottom_inset = Screen:scaleBySize(BOTTOM_CONTENT_INSET)
            -- 内容上移时同时向内扩背景，不能让文字或进度条漏到正文上。
            bottom_y = bottom_y - bottom_inset
            bb:paintRect(x, bottom_y, w, bar_h + bottom_inset, bg)
            local margin_l, margin_r = bottomMargins(footer)
            Items.paint(
                bb, x + margin_l, bottom_y, math.max(1, w - margin_l - margin_r), bar_h,
                Layout.get("bottom"), ctx, {
                    face = footer.footer_text_face,
                    fgcolor = footer.footer_text.fgcolor,
                    cache = cache,
                    bar_h = footer.progress_bar and footer.progress_bar.height,
                    prefix = "bottom:",
                }
            )
        end
    end
end

return Bars
