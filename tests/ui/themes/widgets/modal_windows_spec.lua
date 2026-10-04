--[[--
继承主题 Modal 的独立窗口（任务列表 / 搜刮结果 / 翻译弹窗 / 阅读侧栏）接真 Modal 的冒烟用例：
能构造、面板经 setPanel 定位、能画、绘制与事件都走 Modal 的 guard 入口。各窗口自身逻辑见各自 spec。

@module tests.ui.themes.widgets.modal_windows_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, inject-field

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")

local Leaf = { new = function(_, o)
    o = o or {}
    o.getSize = function(self) return { w = self.width or 10, h = self.height or 10 } end
    o.paintTo = function() end
    return o
end }
package.preload["ui/size"] = function()
    return {
        padding = { default = 4, large = 8, small = 2 },
        margin = { tiny = 1 },
        radius = { window = 4 },
        border = { window = 2 },
        line = { medium = 1 },
    }
end
package.preload["ui/widget/progresswidget"] = function() return Leaf end
package.preload["ui/widget/button"] = function()
    return { new = function(_, o) o = Leaf:new(o); o.setText = function() end; return o end }
end
package.preload["ui/widget/buttontable"] = function() return Leaf end
package.preload["ui/widget/titlebar"] = function() return Leaf end
package.preload["ui/widget/scrolltextwidget"] = function()
    return { new = function(_, o)
        o = Leaf:new(o)
        o.text_widget = { setText = function() end }
        o.resetScroll, o.scrollToTop = function() end, function() end
        return o
    end }
end
package.preload["ui.widgets.bookhero"] = function()
    return { widget = function(_, _, _, opts) return Leaf:new{ width = opts.width, height = 100 } end }
end
package.preload["features.translate.edge"] = function() return {} end
package.preload["features.translate.languages"] = function()
    return { displayName = function(_, code) return code or "auto" end }
end
package.preload["ui.fonts.reader"] = function() return { supports = function() return false end } end
package.preload["features.sidebar.info"] = function()
    return { build = function(_, w, h) return Leaf:new{ width = w, height = h } end }
end
Kit.sections.reader = {}
Kit.sections.xray = { book_xray_enabled = true }
require("device").hasClipboard = function() return false end

local Modal = require("ui.themes.widgets.modal")

--- 窗口接的是真 Modal：paintTo / handleEvent 没被子类覆盖（覆盖会绕过 guard）。
---@param w table
local function assertModal(w)
    Assert.eq(w.paintTo, Modal.paintTo)
    Assert.eq(w.handleEvent, Modal.handleEvent)
    Assert.eq(w.dimen.w, Kit.SCREEN_W)
    Assert.eq(w.dimen.h, Kit.SCREEN_H)
end

-- 任务列表：居中面板
local TaskDialog = require("workers.ui.task_dialog")
local tasks = TaskDialog:new{}
assertModal(tasks)
tasks:paintTo(Kit.canvas(), 0, 0)
local size = tasks.frame:getSize()
Assert.eq(tasks.panel_x, math.floor((Kit.SCREEN_W - size.w) / 2), "面板水平居中")
Assert.eq(tasks.panel_y, math.floor((Kit.SCREEN_H - size.h) / 2), "面板垂直居中")
Assert.is_true(tasks:handleEvent({ handler = "onTapModal", args = { nil, Kit.tap(1, 1) } }))
Assert.eq(Kit.closed[#Kit.closed], tasks, "点空白收起")

-- 搜刮结果：整屏页，不画遮罩
local Results = require("scrape.results")
local results = Results:new{ results = { { title = "书", author = "人", cover_url = "" } }, source = "douban" }
assertModal(results)
Assert.eq(results.panel_x, 0)
Assert.eq(results.panel_y, 0)
local bb = Kit.canvas()
results:paintTo(bb, 0, 0)
Assert.eq(bb.pixels, 0, "整屏页不画网状遮罩")

-- 翻译弹窗：居中，宽度字段不与 Modal.width 撞名（布局仍整屏）
local Popup = require("features.translate.popup")
local popup = Popup.TranslatePopup:new{ translator = {}, text = "原文", translated = "译文" }
assertModal(popup)
Assert.eq(popup.popup_w, math.floor(math.min(Kit.SCREEN_W, Kit.SCREEN_H) * 0.88))
Assert.eq(popup.panel_x, math.floor((Kit.SCREEN_W - popup[1]:getSize().w) / 2))
popup:paintTo(Kit.canvas(), 0, 0)

-- 阅读侧栏：面板贴左上、整屏；点遮罩关
local Sidebar = require("features.sidebar")
local sidebar = Sidebar:new{ ui = {}, snapshot = { identity = {} } }
assertModal(sidebar)
Assert.eq(sidebar.panel_x, 0)
Assert.eq(sidebar.panel_y, 0)
Assert.not_nil(sidebar.ges_events.TapModal, "Modal 的点按手势还在")
Assert.not_nil(sidebar.ges_events.SwipeSidebar, "侧栏滑动手势追加在后")
sidebar:paintTo(Kit.canvas(), 0, 0)
Assert.is_true(sidebar:handleEvent({ handler = "onTapModal", args = { nil, Kit.tap(Kit.SCREEN_W - 1, 10) } }))
Assert.eq(Kit.closed[#Kit.closed], sidebar)

return true
