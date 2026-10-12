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
    }
end
local session_current = nil
package.preload["reader.session"] = function()
    return { current = function() return session_current end }
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
    doc_settings = { flush = function() end },
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
Assert.is_false(Bars.topVisible(ui_top))

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
Assert.is_true(footer:onHoldFooter())
Assert.is_false(registered_touch_zone)
Assert.len(post_ready, 1, "偏好等 ReaderReady 收尾后再应用")

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
