---@diagnostic disable: missing-fields
--[[--
features.bars.init 离线用例：时间 / 进度文案生成与系统栏可见性。

@module tests.features.bars.init_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
Stubs.reset()

G_reader_settings = G_reader_settings or {}
G_reader_settings.saveSetting = function() end

package.preload["device"] = function()
    return {
        screen = {
            scaleBySize = function(_, n) return n end,
            getWidth = function() return 600 end,
            getHeight = function() return 800 end,
        },
        isTouchDevice = function() return true end,
    }
end
package.preload["ui/event"] = function()
    return {
        new = function(_, name, ...)
            return { name = name, args = { ... } }
        end,
    }
end
package.preload["ui/geometry"] = function()
    return {
        new = function(_, opts) return opts end,
    }
end

local layouts = { top = {}, bottom = {} }
local replace = { top = true, bottom = true }
package.preload["features.bars.layout"] = function()
    return {
        replace = function(which) return replace[which] end,
        get = function(which) return layouts[which] end,
        setReplace = function() end,
        topHeight = function() return 12 end,
        BAR_HORIZONTAL_PADDING = 12,
        fontSize = function(_which, fs) return fs and fs.text_font_size or 14 end,
    }
end
local session_current = nil
package.preload["reader.session"] = function()
    return {
        current = function() return session_current end,
        toc = function() return session_current and session_current._toc end,
        chapterPages = function(cur)
            cur = cur or session_current
            if not cur then return nil end
            return cur.page, cur.total_pages
        end,
        bookPages = function(cur)
            cur = cur or session_current
            if not cur then return 0, 0 end
            return cur.page or 0, cur.total_pages or 0
        end,
        chapterTitle = function() return session_current and session_current._chapter end,
        chapterIndex = function() return session_current and session_current.identity and session_current.identity.chapter_idx end,
        remainingSeconds = function() return nil end,
    }
end
local Bars = require("features.bars")
local UIManager = require("ui/uimanager")
local dirty = {}
UIManager.setDirty = function(_, widget, mode, rect)
    dirty[#dirty + 1] = { widget = widget, mode = mode, rect = rect }
end

-- timeText：HH:MM
Assert.is_true(Bars.timeText(0):match("^%d%d:%d%d$") ~= nil)
Assert.is_true(Bars.timeText():match("^%d%d:%d%d$") ~= nil)

-- remainingText：不足一分钟为空；分钟 / 小时 + 分钟
Assert.eq(Bars.remainingText(nil), "")
Assert.eq(Bars.remainingText(59), "")
Assert.eq(Bars.remainingText(60), "约 1 分钟")
Assert.eq(Bars.remainingText(5400), "约 1 小时 30 分")

-- topVisible / bottomVisible
local events = {}
local ui_top = {
    rolling = true,
    document = {
        getHeaderHeight = function() return 28 end,
        configurable = { status_line = 0, h_page_margins = { 10, 10 }, saveSettings = function() end },
    },
    doc_settings = { flush = function() end, readSetting = function() return 0 end },
    dialog = "reader-dialog",
    view = {
        view_mode = "page",
        dimen = { w = 600, h = 800 },
        state = { offset = { y = 12 } },
        footer_visible = true,
        footer = {
            getHeight = function() return 32 end,
            mode = 1,
            mode_list = { off = 0, page_progress = 1 },
            applyFooterMode = function(self, mode)
                self.mode = mode
                self.ui.view.footer_visible = mode ~= self.mode_list.off
            end,
            onUpdateFooter = function() end,
            rescheduleFooterAutoRefreshIfNeeded = function() end,
            footer_positioner = {
                dimen = { h = 800, y = 0 },
                contentRange = function()
                    return { x = 0, y = 768, w = 600, h = 32 }
                end,
            },
        },
    },
    handleEvent = function(_, event) events[#events + 1] = event end,
}
ui_top.view.footer.ui = ui_top
Assert.is_true(Bars.topVisible(ui_top))
Assert.is_true(Bars.bottomVisible(ui_top))

ui_top.document.getHeaderHeight = function() return 0 end
Assert.is_false(Bars.topVisible(ui_top))

ui_top.document.getHeaderHeight = function() return 28 end
ui_top.view.view_mode = "scroll"
Assert.is_true(Bars.topVisible(ui_top), "滚动模式同样留页眉高度，顶栏须绘制")

-- 渲染不可见不等于配置关闭：滚动模式下仍须写入 status_line。
ui_top.document.configurable.status_line = 0
events = {}
Bars.setSystemTop(ui_top, false)
Assert.eq(events[1].args[2], 1)

ui_top.view.view_mode = "page"
ui_top.view.footer_visible = false
Assert.is_false(Bars.bottomVisible(ui_top))

-- setTopBarPreference：按显隐同步 ConfigChange + SetStatusLine
-- 顶栏当前可见（getHeaderHeight 28 + page 模式），关掉它 → status_line 置 1
ui_top.document.configurable.status_line = 0
events = {}
Bars.setTopBarPreference(false, ui_top)
Assert.eq(events[1].name, "ConfigChange")
Assert.eq(events[1].args[1], "status_line")
Assert.eq(events[1].args[2], 1)
Assert.eq(events[2].name, "SetStatusLine")
Assert.eq(events[2].args[1], 1)
-- 顶栏已隐藏，打开它 → status_line 置 0
ui_top.document.getHeaderHeight = function() return 0 end
ui_top.document.configurable.status_line = 1
events = {}
Bars.setTopBarPreference(true, ui_top)
Assert.eq(events[1].args[2], 0)
Assert.eq(events[2].args[1], 0)

-- setSystemBottom：直接落到目标模式，关闭后可恢复原模式
ui_top.view.footer.mode = 1
ui_top.view.footer_visible = true
Bars.setSystemBottom(ui_top, false)
Assert.eq(ui_top.view.footer.mode, 0)
Assert.is_false(ui_top.view.footer_visible)
Bars.setSystemBottom(ui_top, true)
Assert.eq(ui_top.view.footer.mode, 1)
Assert.is_true(ui_top.view.footer_visible)

-- injectStatusLine：渲染前按偏好写 sidecar；非 CRE 文档不碰
local sidecar = {}
local doc_settings = { saveSetting = function(_, k, v) sidecar[k] = v end }
local cre = { setStatusLineProp = function() end }
Bars.setTopBarPreference(true)
Bars.injectStatusLine(doc_settings, cre)
Assert.eq(sidecar.copt_status_line, 0)
Bars.setTopBarPreference(false)
Bars.injectStatusLine(doc_settings, cre)
Assert.eq(sidecar.copt_status_line, 1)
sidecar = {}
Bars.injectStatusLine(doc_settings, {})
Assert.is_nil(sidecar.copt_status_line)
Bars.setTopBarPreference(true)

-- hijackFooter：底栏可见时短按透传给翻页区，长按阻止切换模式
local update_args
local footer = {
    ui = ui_top,
    view = ui_top.view,
    mode = 1,
    mode_list = { off = 0, page_progress = 1 },
    TapFooter = function() return "original tap" end,
    onHoldFooter = function() return "original hold" end,
    onUpdateFooter = function(_, force_repaint, full_repaint)
        update_args = { force_repaint, full_repaint }
    end,
    onToggleFooterMode = function(self)
        self.mode = self.mode == 0 and 1 or 0
        self.view.footer_visible = self.mode ~= 0
        return true
    end,
    applyFooterMode = function() end,
    rescheduleFooterAutoRefreshIfNeeded = function() end,
    getHeight = function() return 32 end,
}
ui_top.view.footer = footer
ui_top.view.footer_visible = true
ui_top._book_bars_installed = nil
local registered_touch_zone = false
local post_ready = {}
ui_top.registerTouchZones = function() registered_touch_zone = true end
ui_top.registerPostReaderReadyCallback = function(_, cb) post_ready[#post_ready + 1] = cb end
Bars.install(ui_top)
Assert.is_false(footer:TapFooter())
-- 长按落在正文区（底栏矩形上方、仍在原生底部 1/13 hold 区）必须透传给选字；
-- 只有落在底栏矩形内才吞掉阻止切换模式。测试底栏矩形为 y 764..800。
Assert.eq(footer:onHoldFooter({ pos = { x = 100, y = 700 } }), "original hold")
Assert.is_true(footer:onHoldFooter({ pos = { x = 100, y = 780 } }))
Assert.eq(footer:onHoldFooter(), "original hold")
Assert.is_false(registered_touch_zone)
Assert.len(post_ready, 1, "偏好等 ReaderReady 收尾后再应用")

-- 开书诊断（issue #67）：偏好应用后落一行顶栏各门状态。
local Log = require("utils.log")
local diag_args
local orig_info = Log.info
Log.info = function(...) diag_args = { ... } end
post_ready[1]()
Log.info = orig_info
Assert.eq(diag_args[1], "bars top diag")

-- 强制重写页眉高度：配置已是开但高度为 0（被别的插件压掉）时，偏好应用须绕过
-- setSystemTop 的早退、重发状态栏事件逼引擎重排；高度正常时不发任何事件。
ui_top.document.configurable.status_line = 0
ui_top.document.getHeaderHeight = function() return 0 end
events = {}
Bars.applyPreferences(ui_top)
local forced = 0
for _idx, e in ipairs(events) do
    if e.name == "SetStatusLine" and e.args[1] == 0 then forced = forced + 1 end
end
Assert.eq(forced, 1)
ui_top.document.getHeaderHeight = function() return 28 end
events = {}
Bars.applyPreferences(ui_top)
Assert.len(events, 0)

-- 强制重画：月读画底栏时改走整页重画，不让原生底栏盖上来
footer:onUpdateFooter(true)
Assert.is_true(update_args[2])
footer:onUpdateFooter()
Assert.is_nil(update_args[2], "非强制重画（翻页）不碰")
replace.bottom = false
footer:onUpdateFooter(true)
Assert.is_nil(update_args[2], "替代关闭时保持原生快路径")
replace.bottom = true

-- 用户点底栏 / 手势切模式：回写底栏偏好
replace.bottom = false
Assert.is_true(Bars.bottomBarPreference())
Assert.is_true(footer:onToggleFooterMode())
Assert.is_false(Bars.bottomBarPreference())
footer:onToggleFooterMode()
Assert.is_true(Bars.bottomBarPreference())
replace.bottom = true

-- 用户经 Aa 菜单开关顶栏：回写顶栏偏好；返回 nil 不吞事件
Assert.is_nil(Bars.events.SetStatusLine(nil, 1))
Assert.is_false(Bars.topBarPreference())
Bars.events.SetStatusLine(nil, 0)
Assert.is_true(Bars.topBarPreference())

-- 设备状态事件：只刷含动态组件、且由月读画的栏
local plugin = { ui = ui_top }
ui_top.document.getHeaderHeight = function() return 28 end
session_current = {}
layouts.top = { { id = "chapter", align = "left" } }
layouts.bottom = { { id = "progress_bar", align = "left" } }
dirty = {}
Assert.is_nil(Bars.events.UpdateFooter(plugin))
Assert.len(dirty, 0, "没有动态组件不刷屏")
layouts.top = { { id = "clock", align = "right" } }
layouts.bottom = { { id = "battery", align = "right" } }
Bars.events.FrontlightStateChanged(plugin)
Assert.len(dirty, 2)
Assert.eq(dirty[1].widget, "reader-dialog")
Assert.eq(dirty[1].rect.h, 28 + 12, "顶栏 = 页眉 + 额外高度")
Assert.eq(dirty[2].rect.y, 768 - 4, "底栏向上让出内缩")
Assert.eq(dirty[2].rect.h, 32 + 4)

-- 绘制：字体现取月读界面字体（ffont），不复用 footer_text_face；进度条高度不复用
-- ReaderFooter.progress_bar.height（KOReader 关掉原生进度条时为 0）。
do
    local Session = require("reader.session")
    Session.toc = function() return {} end
    Session.chapterPages = function() return nil end
    Session.chapterTitle = function() return "" end
    Session.chapterIndex = function() return 1 end
    Session.remainingSeconds = function() return nil end
    session_current = { identity = {}, percent = 0.5 }
    local painted = {}
    package.loaded["features.bars.items"] = {
        paint = function(_bb, x, _y, w, h, _layout, _ctx, opts)
            painted[#painted + 1] = { x = x, w = w, h = h, opts = opts }
        end,
    }
    local faces = {}
    package.loaded["ui/font"] = {
        getFace = function(_, name, size)
            faces[#faces + 1] = name
            return { name = name, size = size }
        end,
    }
    local layout_mod = require("features.bars.layout")
    layout_mod.icons = function() return false end
    local divided = { top = true, bottom = false }
    layout_mod.divider = function(which) return divided[which] end
    ui_top.view.footer.settings = { text_font_size = 14, progress_margin_width = 10, text_font_face = "stale" }
    ui_top.view.footer.horizontal_margin = 4
    ui_top.view.footer.footer_text_face = "stale-face"
    ui_top.view.footer.progress_bar = { height = 0 }
    ui_top.view.footer_visible = true
    Bars.ui = ui_top
    local rects = {}
    Bars:paintTo({ paintRect = function(_bb, x, y, w, h) rects[#rects + 1] = { x = x, y = y, w = w, h = h } end }, 0, 0)
    Assert.len(painted, 2)
    local lines = 0
    for _idx, r in ipairs(rects) do if r.h == 1 then lines = lines + 1 end end
    Assert.eq(lines, 1, "只有开了分割线的顶栏画一条 1px 线")
    for _idx, name in ipairs(faces) do
        Assert.eq(name, "ffont", "栏字体跟随月读界面字体")
    end
    Assert.eq(painted[2].opts.face.name, "ffont")
    Assert.is_nil(painted[2].opts.bar_h, "不吃原生进度条的 0 高度")
    Assert.eq(painted[2].h, 32, "底栏内容区 = 条带（扣掉内缩）")
    Assert.eq(painted[1].x, 12, "顶栏水平留白")
    Assert.eq(painted[2].x, 12, "底栏与顶栏同一水平留白，不叠加 footer 边距")
    Assert.eq(painted[2].w, 600 - 24)
    local dogears = {}
    ui_top.view.dogear = {
        paintTo = function(_self, _bb, x, y)
            dogears[#dogears + 1] = { x = x, y = y, painted = #painted }
        end,
    }
    local bb = { paintRect = function() end }
    ui_top.view.dogear_visible = true
    painted = {}
    Bars:paintTo(bb, 5, 7)
    Assert.len(dogears, 1)
    Assert.eq(dogears[1].painted, 1, "顶栏内容绘制完成后恢复原生书签折角")
    Assert.eq(dogears[1].x, 5)
    Assert.eq(dogears[1].y, 7)
    ui_top.view.dogear_visible = false
    Bars:paintTo(bb, 0, 0)
    Assert.len(dogears, 1, "取消书签后不重画折角")
    ui_top.view.dogear_visible = true
    replace.top = false
    Bars:paintTo(bb, 0, 0)
    Assert.len(dogears, 1, "未替代顶栏时保留原生绘制，不重复画折角")
    replace.top = true
    ui_top.view.dogear_visible = false
    package.loaded["features.bars.items"] = nil
    package.loaded["ui/font"] = nil
end
dirty = {}
session_current = nil
Bars.events.Charging(plugin)
Assert.len(dirty, 0, "非月读会话不刷")
session_current = {}
Bars.events.Charging({ ui = {} })
Assert.len(dirty, 0, "文件管理器侧没有文档")

-- 底栏关闭后恢复 ReaderFooter 原有行为
ui_top.view.footer_visible = false
Assert.eq(footer:TapFooter(), "original tap")
Assert.eq(footer:onHoldFooter(), "original hold")

-- 时钟：关书即停，不留定时器
Bars.ui = ui_top
Bars:startClock()
Assert.not_nil(Bars._clock)
Bars.events.CloseDocument(plugin)
Assert.is_nil(Bars._clock)
