--[[--
上下进度条（ReaderView view module）。

纯绘制叠加层：叠在 KOReader 原生顶栏 / 底栏之上，背景不透明盖住引擎内容。
几何跟系统状态栏同步；开启跟随系统，替代开关决定要不要盖住原栏。
底栏短按透传给原生翻页区，长按只用于阻止 ReaderFooter 切换模式。

刷新：翻页由 ReaderView 整页重画带上；时钟每分钟、设备状态事件经 refreshBars
只刷栏区域；原生底栏的「只重画底栏」快路径被改成整页重画，免得盖住月读底栏。

@module koplugin.book.features.bars.init
--]]

local Device = require("device")
local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local Layout = require("features.bars.layout")
local Guard = require("ui.guard")
local _ = require("gettext")
local Screen = Device.screen

--- 底栏文字向屏幕内侧偏移，避免视觉上贴住边缘。
local BOTTOM_CONTENT_INSET = 4
--- 栏文字字体：跟随月读界面字体。ui.fonts.applyCurrent 把 ffont 等 UI 别名映射到用户所选字体；
--- 每次绘制现取 face（Font 自带缓存），换字体后下一次重绘即生效，不用重开书。
--- 不读 ReaderFooter.footer_text_face：它在 footer init 时取一次，早于插件改 fontmap 或之后换字体都会过期。
local BAR_FONT = "ffont"
--- 不随翻页变化、要靠时钟或设备事件重画的组件。
local LIVE_ITEMS = { clock = true, battery = true, wifi = true, brightness = true, remaining = true }

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
        if widget.free then
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

--- 写偏好；值没变不落盘（原生入口回写时每次事件都会调到这里）。
---@param key string
---@param on boolean
local function savePreference(key, on)
    local MoonSettings = require("utils.settings")
    local settings = MoonSettings.get("features.bars")
    if settings[key] == on then
        return
    end
    settings[key] = on
    MoonSettings.save("features.bars", settings)
end

--- 设置系统顶栏开/关（同步 configurable + crengine，与 Aa 菜单一致）。
---@param ui table ReaderUI
---@param enabled boolean
function Bars.setSystemTop(ui, enabled)
    if not ui.rolling or not ui.document then
        return
    end
    local config = ui.document.configurable
    local next_val = enabled and 0 or 1
    if config.status_line == next_val then
        return
    end
    local Event = require("ui/event")
    ui:handleEvent(Event:new("ConfigChange", "status_line", next_val))
    ui:handleEvent(Event:new("SetStatusLine", next_val))
    config:saveSettings(ui.doc_settings, "copt_")
    ui.doc_settings:flush()
end

--- 设置系统底栏开/关（走原生 ReaderFooter 的模式切换）。
--- 目标状态与当前一致时直接返回，避免把 footer 切到别的模式。
---@param ui table ReaderUI
---@param enabled boolean 是否显示系统底栏
function Bars.setSystemBottom(ui, enabled)
    if Bars.bottomVisible(ui) == enabled then
        return
    end
    local footer = ui.view.footer
    local mode
    if enabled then
        mode = footer._book_bars_mode or footer.mode_list.page_progress
    else
        footer._book_bars_mode = footer.mode
        mode = footer.mode_list.off
    end
    footer:applyFooterMode(mode)
    G_reader_settings:saveSetting("reader_footer_mode", mode)
    footer:onUpdateFooter(true)
    footer:rescheduleFooterAutoRefreshIfNeeded()
end

--- 顶栏偏好（默认开）。
---@return boolean
function Bars.topBarPreference()
    return require("utils.settings").get("features.bars").book_reader_top_bar
end

--- 底栏偏好（默认开）。
---@return boolean
function Bars.bottomBarPreference()
    return require("utils.settings").get("features.bars").book_reader_bottom_bar
end

--- 写入顶栏偏好，并在阅读中时立即应用。
---@param enabled boolean
---@param ui table|nil 正在阅读的 ReaderUI；不在阅读时为 nil，下次开书应用
function Bars.setTopBarPreference(enabled, ui)
    savePreference("book_reader_top_bar", enabled)
    if ui then
        Bars.setSystemTop(ui, enabled)
    end
end

--- 写入底栏偏好，并在阅读中时立即应用。
---@param enabled boolean
---@param ui table|nil 正在阅读的 ReaderUI；不在阅读时为 nil，下次开书应用
function Bars.setBottomBarPreference(enabled, ui)
    savePreference("book_reader_bottom_bar", enabled)
    if ui then
        Bars.setSystemBottom(ui, enabled)
    end
end

--- DocSettingsLoad：首次渲染前把顶栏偏好写进 sidecar。
--- 页眉高度变化会让 crengine 整本重排，拖到 ReaderReady 再切，新书就要排两遍。
---@param doc_settings table
---@param document table
function Bars.injectStatusLine(doc_settings, document)
    if not Device:isTouchDevice() or type(document.setStatusLineProp) ~= "function" then
        return
    end
    doc_settings:saveSetting("copt_status_line", Bars.topBarPreference() and 0 or 1)
end

--- 按 Book 设置同步系统顶底栏。
---@param ui table ReaderUI
function Bars.applyPreferences(ui)
    Bars.setSystemTop(ui, Bars.topBarPreference())
    Bars.setSystemBottom(ui, Bars.bottomBarPreference())
end

--- 顶栏 overlay 是否应绘制（系统 Alt Status Bar 开）。
--- 关书时 closeDocument 先清 document，ReaderUI 还在，这段时间不画。
---@param ui table ReaderUI
---@return boolean
function Bars.topVisible(ui)
    if not ui.document or not ui.rolling or ui.view.view_mode ~= "page" then
        return false
    end
    return ui.document:getHeaderHeight() > 0
end

--- 底栏 overlay 是否应绘制（系统 ReaderFooter 开）。
---@param ui table ReaderUI
---@return boolean
function Bars.bottomVisible(ui)
    return ui.view.footer_visible
end

--- 该栏此刻是否由月读画（系统栏开着且开了替代）。
---@param ui table ReaderUI
---@param which string "top"|"bottom"
---@return boolean
local function drawn(ui, which)
    local visible
    if which == "top" then
        visible = Bars.topVisible(ui)
    else
        visible = Bars.bottomVisible(ui)
    end
    return visible and Layout.replace(which)
end

--- 顶栏在 ReaderView paintTo 坐标下的矩形。
---@param ui table ReaderUI
---@param x number
---@param y number
---@return number header_h
---@return table rect
local function topRect(ui, x, y)
    local header_h = ui.document:getHeaderHeight()
    -- ReaderView.state.offset 属于文档可视区，不是状态栏几何，不能混进来。
    return header_h, Geom:new{
        x = x,
        y = y,
        w = ui.view.dimen.w,
        h = header_h + Screen:scaleBySize(Layout.topHeight()),
    }
end

--- 底栏在 ReaderView paintTo 坐标下的矩形（对齐 BottomContainer 内容区，背景补到物理屏底；
--- 再向上让出 BOTTOM_CONTENT_INSET，不让文字或进度条漏到正文上）。
---@param ui table ReaderUI
---@param x number
---@param y number
---@return table|nil
local function bottomRect(ui, x, y)
    local view, footer = ui.view, ui.view.footer
    local pos = footer.footer_positioner
    local screen_h = Screen:getHeight()
    local view_h = view.dimen.h
    local band_y, band_h
    if pos and pos.contentRange then
        band_h = pos:contentRange().h
        band_y = y + (pos.dimen and pos.dimen.y or 0) + (pos.dimen and pos.dimen.h or view_h) - band_h
    else
        band_h = footer:getHeight()
        if band_h <= 0 then
            return nil
        end
        band_y = y + view_h - band_h
    end
    local inset = Screen:scaleBySize(BOTTOM_CONTENT_INSET)
    return Geom:new{
        x = x,
        y = band_y - inset,
        w = view.dimen.w,
        h = math.max(band_h, y + screen_h - band_y) + inset,
    }
end

--- 该栏布局里有没有随时间 / 设备状态变化的组件。
---@param which string
---@return boolean
local function hasLiveItems(which)
    for _idx, slot in ipairs(Layout.get(which)) do
        if LIVE_ITEMS[slot.id] then
            return true
        end
    end
    return false
end

--- 只刷新月读正在画、且含动态组件的栏区域；ReaderView 整页重画时会重新取数。
---@param ui table ReaderUI
local function refreshBars(ui)
    if not require("reader.session").current() then
        return
    end
    local UIManager = require("ui/uimanager")
    if drawn(ui, "top") and hasLiveItems("top") then
        local _header_h, rect = topRect(ui, 0, 0)
        UIManager:setDirty(ui.dialog, "ui", rect)
    end
    if drawn(ui, "bottom") and hasLiveItems("bottom") then
        local rect = bottomRect(ui, 0, 0)
        if rect then
            UIManager:setDirty(ui.dialog, "ui", rect)
        end
    end
end

--- 顶栏文字 face：跟随月读界面字体；字号用顶栏自己的设置（未设置跟随底栏）；超出条带高度时等比缩小。
---@param footer table ReaderFooter
---@param bar_h number
---@return table
local function topTextFace(footer, bar_h)
    local s = footer.settings
    local size = Layout.fontSize("top", s)
    local scaled = Screen:scaleBySize(size)
    if bar_h > 2 and scaled > bar_h - 2 then
        size = math.max(8, math.floor(size * (bar_h - 2) / scaled))
    end
    return require("ui/font"):getFace(BAR_FONT, size)
end

--- 底栏文字 face：字体跟随月读界面字体，字号用底栏设置。
---@param footer table ReaderFooter
---@return table
local function bottomTextFace(footer)
    return require("ui/font"):getFace(BAR_FONT, Layout.fontSize("bottom", footer.settings))
end

--- 包装 ReaderFooter：
--- - 底栏由月读画时禁止切换模式；短按继续交给原生翻页区，兼容把蓝牙按钮转换为屏幕点击的翻页器。
--- - 强制重画时原生走 widgetRepaint(footer) 只画底栏、不经 ReaderView，会把原栏盖回月读底栏上；
---   改走 full_repaint 分支（整页重画、只刷底栏区域）。
--- - 用户点底栏 / 手势切模式时回写偏好，否则下次开书又被偏好覆盖回去。不包 applyFooterMode：
---   翻页模式进出也调它，临时切换不是用户意图。
--- ReaderFooter:onReaderReady 会把 updateFooterText 指回原方法，所以包 onUpdateFooter（唯一调用口）。
---@param ui table
local function hijackFooter(ui)
    local footer = ui.view.footer
    if footer._book_bars_hijacked then
        return
    end
    -- 原生方法照常调用，只把月读自己的判断经 guard：出错时按「月读没画底栏」退回原生行为。
    local function ours(self)
        return Guard.call("bars footer", drawn, self.ui, "bottom")
    end
    local orig_tap = footer.TapFooter
    footer.TapFooter = function(self, ges)
        if ours(self) then
            return false
        end
        return orig_tap(self, ges)
    end
    local orig_hold = footer.onHoldFooter
    footer.onHoldFooter = function(self, ges)
        if ours(self) then
            return true
        end
        return orig_hold(self, ges)
    end
    local orig_update = footer.onUpdateFooter
    footer.onUpdateFooter = function(self, force_repaint, full_repaint)
        if force_repaint and ours(self) then
            full_repaint = true
        end
        return orig_update(self, force_repaint, full_repaint)
    end
    local orig_toggle = footer.onToggleFooterMode
    footer.onToggleFooterMode = function(self)
        local handled = orig_toggle(self)
        Guard.call("bars save preference", savePreference, "book_reader_bottom_bar", self.view.footer_visible)
        return handled
    end
    footer._book_bars_hijacked = true
end

--- 安装底栏模式保护；偏好等 ReaderReady 收尾后再应用，此时 ReaderRolling 才会响应重排。
---@param ui table
function Bars.install(ui)
    if ui._book_bars_installed or not Device:isTouchDevice() then
        return
    end
    ui._book_bars_installed = true
    hijackFooter(ui)
    ui:registerPostReaderReadyCallback(Guard.wrap("bars preferences", function()
        Bars.applyPreferences(ui)
    end))
end

--- 停时钟、释放文字控件；关书时调。
function Bars:stopClock()
    if self._clock then
        require("ui/uimanager"):unschedule(self._clock)
        self._clock = nil
    end
    clearPaintWidgets()
end

--- 每分钟刷一次含动态组件的栏；关书由 CloseDocument 停摆。
function Bars:startClock()
    local UIManager = require("ui/uimanager")
    self:stopClock()
    -- Bars 是单例，registerViewModule 每次开书都把 self.ui 覆写成新的 ReaderUI：
    -- 闭包里必须捕获本次的 ui，CloseDocument 没送达时旧链条也能自己停摆。
    local ui = self.ui
    -- 出错就停摆（不再续约），免得每分钟弹一次错误页。
    local tick
    tick = Guard.wrap("bars clock", function()
        if require("apps/reader/readerui").instance ~= ui then
            return
        end
        refreshBars(ui)
        UIManager:scheduleIn(61 - tonumber(os.date("%S")), tick)
    end)
    self._clock = tick
    UIManager:scheduleIn(61 - tonumber(os.date("%S")), tick)
end

--- 按章打开的书（微信读书等）每章一个文档，文档页数只是本章页数。
--- 用目录字数估全书页码：每字页数 = 本章页数 / 本章字数。缺字数时返回 nil，沿用文档页码。
---@param toc table[]|nil 章节目录（条目带 words）
---@param idx integer|nil 当前章序号（toc 下标）
---@param page integer|nil 本章当前页
---@param pages integer|nil 本章页数
---@return integer|nil page, integer|nil total
function Bars.estimatePages(toc, idx, page, pages)
    idx, page, pages = tonumber(idx), tonumber(page), tonumber(pages)
    if type(toc) ~= "table" or not idx or not page or not pages or page <= 0 or pages <= 0 then return nil end
    local cur = toc[idx]
    local cur_words = cur and tonumber(cur.words)
    if not cur_words or cur_words <= 0 then return nil end
    local before, total = 0, 0
    for i, ch in ipairs(toc) do
        local w = tonumber(ch.words)
        if not w or w <= 0 then return nil end
        total = total + w
        if i < idx then before = before + w end
    end
    local ratio = pages / cur_words
    local est_total = math.max(math.floor(total * ratio + 0.5), math.floor(before * ratio + 0.5) + pages)
    return math.floor(before * ratio + 0.5) + page, est_total
end

--- 当前阅读会话给栏组件用的上下文；章节标题、序号、目录长度同一时刻现算，不混用翻页快照。
---@return table|nil
local function liveContext()
    local Session = require("reader.session")
    local cur = Session.current()
    if not cur then
        return nil
    end
    local book = cur.identity.book
    local toc = Session.toc()
    local chapter_page, chapter_pages = Session.chapterPages(cur)
    local page, total_pages = cur.page, cur.total_pages
    if cur.identity.chapter_idx ~= nil then
        local p, t = Bars.estimatePages(toc, cur.identity.chapter_idx, cur.page, cur.total_pages)
        if p then page, total_pages = p, t end
    end
    return {
        chapter = Session.chapterTitle(cur) or "",
        title = book and book.title or "",
        clock = Bars.timeText(),
        percent = cur.percent,
        chapter_idx = Session.chapterIndex(cur) or cur.identity.chapter_idx,
        chapter_count = toc and #toc or nil,
        page = page,
        total_pages = total_pages,
        chapter_page = chapter_page,
        chapter_pages = chapter_pages,
        remaining = Bars.remainingText(Session.remainingSeconds()),
    }
end

--- 绘制顶条 / 底条叠加层；替代开关关掉时不画，露出系统原栏。
---@param bb any blitbuffer
---@param x number ReaderView 原点
---@param y number
local function paint(self, bb, x, y)
    local ui = self.ui
    local top, bottom = drawn(ui, "top"), drawn(ui, "bottom")
    if not top and not bottom then
        return
    end
    local ctx = liveContext()
    if not ctx then
        return
    end
    local Items = require("features.bars.items")
    local bg = Blitbuffer.COLOR_WHITE
    local cache = { widgets = Bars._paint_widgets, keys = Bars._paint_widget_keys }
    local icons = Layout.icons()

    if top then
        local header_h, rect = topRect(ui, x, y)
        bb:paintRect(rect.x, rect.y, rect.w, rect.h, bg)
        local margin = Screen:scaleBySize(Layout.BAR_HORIZONTAL_PADDING)
        Items.paint(
            bb, rect.x + margin, rect.y, math.max(1, rect.w - margin * 2), rect.h,
            Layout.get("top"), ctx, {
                face = topTextFace(ui.view.footer, header_h),
                fgcolor = Blitbuffer.COLOR_BLACK,
                cache = cache,
                prefix = "top:",
                icons = icons,
            }
        )
    end

    local rect = bottom and bottomRect(ui, x, y)
    if rect then
        local footer = ui.view.footer
        bb:paintRect(rect.x, rect.y, rect.w, rect.h, bg)
        -- 与顶栏同一固定水平留白。不用 ReaderFooter 的 horizontal_margin + progress_margin_width：
        -- 两者叠加约 20px，progress_margin_width 还可能跟随书籍页边距，Android 缺省值又被再缩放一次。
        local margin = Screen:scaleBySize(Layout.BAR_HORIZONTAL_PADDING)
        Items.paint(
            bb, rect.x + margin, rect.y, math.max(1, rect.w - margin * 2),
            rect.h - Screen:scaleBySize(BOTTOM_CONTENT_INSET),
            Layout.get("bottom"), ctx, {
                face = bottomTextFace(footer),
                fgcolor = Blitbuffer.COLOR_BLACK,
                cache = cache,
                -- 不传 bar_h：进度条用主题高度（与预览一致）。ReaderFooter.progress_bar.height 在
                -- KOReader 底栏「显示进度条」关掉时被 resetLayout 置 0，复用它会让进度条开着却画不出来。
                prefix = "bottom:",
                icons = icons,
            }
        )
    end
end

--- ReaderView 每次重绘都调；经 guard 隔离，画坏了只丢状态栏，不带崩阅读页。
---@param bb any blitbuffer
---@param x number
---@param y number
function Bars:paintTo(bb, x, y)
    Guard.paint("bars.paintTo", paint, self, bb, x, y)
end

--- 设备状态变了：重画含动态组件的栏。只在阅读器侧有意义；返回 nil 不吞事件。
---@param plugin BookPlugin
local function onDeviceStateChanged(plugin)
    if plugin.ui.document then
        refreshBars(plugin.ui)
    end
end

--- KOReader 事件。亮度调节由 DeviceListener 发 UpdateFooter，前光开关才发 FrontlightStateChanged。
Bars.events = {
    UpdateFooter = onDeviceStateChanged,
    FrontlightStateChanged = onDeviceStateChanged,
    Charging = onDeviceStateChanged,
    NotCharging = onDeviceStateChanged,
    NetworkConnected = onDeviceStateChanged,
    NetworkDisconnected = onDeviceStateChanged,
    --- 用户经原生入口（Aa 菜单）开关顶栏时回写偏好；0 = 显示。
    SetStatusLine = function(_plugin, status_line)
        savePreference("book_reader_top_bar", status_line == 0)
    end,
    CloseDocument = function(_plugin)
        Bars:stopClock()
    end,
}

--- 阅读页创建、首绘之前安装。install 用点号调用：冒号会把模块自己绑成 ui。
---@param plugin BookPlugin
function Bars.onReaderReady(plugin)
    local ui = plugin.ui
    ui.view:registerViewModule("book_bars", Bars)
    Bars.install(ui)
    Bars:startClock()
end

-- 扩展点登记（features 加载器 require 本模块时执行一次；见 utils/extension.lua）。
local Ext = require("utils.extension")
Ext.add("reader.doc_settings", function(doc_settings, document) return Bars.injectStatusLine(doc_settings, document) end)
Ext.add("reader.preferences", function(ui) return Bars.applyPreferences(ui) end)

return Bars
