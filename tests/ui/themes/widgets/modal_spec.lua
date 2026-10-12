--[[--
ui.themes.widgets.modal 及其弹窗（confirm / toast / sheet / progress_dialog / qr）：
面板内外点按分流、取消语义、先关窗再回调、定时收起、进度原地更新。

@module tests.ui.themes.widgets.modal_spec
--]]

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")

local Confirm = require("ui.themes.widgets.confirm")
local ProgressDialog = require("ui.themes.widgets.progress_dialog")
local QR = require("ui.themes.widgets.qr")
local Sheet = require("ui.themes.widgets.sheet")
local Toast = require("ui.themes.widgets.toast")

--- 模拟一次上屏绘制，面板拿到坐标。
local function paint(w)
    w:paintTo(Kit.canvas(), 0, 0)
    return w[1].dimen
end

-- 确认框：面板居中，宽度 = min(屏宽 - 4 * lg, 480)；取消在左、确定在右。
local log = {}
local confirm = Confirm:new{
    text = "删除？",
    ok_callback = function() log[#log + 1] = "ok:" .. #Kit.closed end,
    cancel_callback = function() log[#log + 1] = "cancel:" .. #Kit.closed end,
    close_callback = function() log[#log + 1] = "closed" end,
}
confirm:show()
Assert.eq(Kit.shown[1], confirm)
local panel = paint(confirm)
Assert.eq(panel.w, 480, "600 宽屏命中封顶")
Assert.eq(panel.x, math.floor((600 - panel.w) / 2))
Assert.eq(panel.y, math.floor((800 - panel.h) / 2))
local bb = Kit.canvas()
confirm:paintTo(bb, 0, 0)
Assert.eq(bb.pixels, 600 * 800 / 4, "居中弹窗画网状遮罩：每 4 像素一点")
Kit.display.mesh_mask = false
bb = Kit.canvas()
confirm:paintTo(bb, 0, 0)
Assert.eq(bb.pixels, 0, "mesh_mask 关闭不画")
Kit.display.mesh_mask = true
local buttons = Kit.buttons(confirm)
Assert.len(buttons, 2)
Assert.eq(buttons[1].text, "取消")
Assert.eq(buttons[2].text, "确定")
Assert.eq(buttons[2].variant, "primary")

-- 点面板内空白：吞掉不关。
Assert.is_true(confirm:onTapModal(nil, Kit.tap(panel.x + 1, panel.y + 1)))
Assert.len(Kit.closed, 0)

-- 确定：先关窗再回调；close_callback 只调一次。
buttons[2]:onTapThemeButton()
Assert.eq(log[1], "closed")
Assert.eq(log[2], "ok:1")
confirm:onCloseWidget()
Assert.len(log, 2)

-- 点面板外 = 取消；返回键同理。
Kit.install("paper")
Confirm = require("ui.themes.widgets.confirm")
log = {}
confirm = Confirm:new{ text = "x", cancel_callback = function() log[#log + 1] = "cancel" end }
paint(confirm)
Assert.is_true(confirm:onTapModal(nil, Kit.tap(1, 1)))
Assert.eq(log[1], "cancel")
confirm = Confirm:new{ text = "x", cancel_callback = function() log[#log + 1] = "back" end }
Assert.is_true(confirm:onClose())
Assert.eq(log[2], "back")

-- dismissable=false：面板外和返回键只吞事件。
confirm = Confirm:new{ text = "x", dismissable = false, cancel_callback = function() log[#log + 1] = "no" end }
paint(confirm)
local closed = #Kit.closed
Assert.is_true(confirm:onTapModal(nil, Kit.tap(1, 1)))
Assert.is_true(confirm:onClose())
Assert.eq(#Kit.closed, closed)
Assert.len(log, 2)

-- 提示：onShow 按 timeout 定时；到点关窗，关窗时撤销定时。
local toast = Toast:new{ text = "已保存", timeout = 2 }
toast:onShow()
Assert.len(Kit.scheduled, 1)
Assert.eq(Kit.scheduled[1].delay, 2)
Kit.scheduled[1].fn()
Assert.eq(Kit.closed[#Kit.closed], toast)
Assert.eq(Kit.unscheduled[1], Kit.scheduled[1].fn)
-- 无 timeout 不定时；面板内点按也收起。
toast = Toast:new{ text = "x" }
toast:onShow()
Assert.len(Kit.scheduled, 1)
panel = paint(toast)
toast:onTapModal(nil, Kit.tap(panel.x + 1, panel.y + 1))
Assert.eq(Kit.closed[#Kit.closed], toast)
-- dismissable=false：面板内外点按、返回键都只吞事件，压过 close_on_tap。
local closed_count = #Kit.closed
toast = Toast:new{ text = "x", dismissable = false }
panel = paint(toast)
Assert.is_true(toast:onTapModal(nil, Kit.tap(panel.x + 1, panel.y + 1)))
Assert.is_true(toast:onTapModal(nil, Kit.tap(1, 1)))
Assert.is_true(toast:onClose())
Assert.eq(#Kit.closed, closed_count, "dismissable=false 的提示不被点按 / 返回键关闭")

-- 动作表：通栏按钮，separator 只占空隙；点按先关窗再执行；禁用项不回调。
log = {}
local sheet
sheet = Sheet:new{ title = "操作", items = {
    { text = "打开", callback = function() log[#log + 1] = "open:" .. tostring(Kit.closed[#Kit.closed] == sheet) end },
    { separator = true },
    { text = "删除", enabled = false, callback = function() log[#log + 1] = "del" end },
} }
buttons = Kit.buttons(sheet)
Assert.len(buttons, 2)
Assert.eq(buttons[1]:getSize().w, sheet:innerWidth())
buttons[1]:onTapThemeButton()
Assert.eq(log[1], "open:true")
buttons[2]:onTapThemeButton()
Assert.len(log, 1)

-- 动作表 buttons 行：一行等宽按钮（ButtonDialog 二维 buttons），同样先关窗再执行。
log = {}
sheet = Sheet:new{ items = {
    { buttons = {
        { text = "复制", callback = function() log[#log + 1] = "copy:" .. tostring(Kit.closed[#Kit.closed] == sheet) end },
        { icon = "share", callback = function() log[#log + 1] = "share" end },
        { text = "禁用", enabled = false },
    } },
    { text = "通栏" },
} }
buttons = Kit.buttons(sheet)
Assert.len(buttons, 4)
local gap = 8
Assert.eq(buttons[1]:getSize().w, math.floor((sheet:innerWidth() - gap * 2) / 3))
Assert.eq(buttons[4]:getSize().w, sheet:innerWidth())
Assert.is_false(buttons[3].enabled)
buttons[1]:onTapThemeButton()
Assert.eq(log[1], "copy:true")

-- 锚点矩形：贴下方弹出、水平对中并夹进屏内；下方放不下翻到上方。
local function anchored(rect)
    local s = Sheet:new{ anchor = rect, mask = false, items = { { text = "a" }, { text = "b" } } }
    return s, paint(s)
end
local s, p = anchored{ x = 100, y = 100, w = 40, h = 30 }
Assert.eq(p.y, 130, "锚点下方")
Assert.eq(p.x, 8, "左侧夹到 sm 边距")
bb = Kit.canvas()
s:paintTo(bb, 0, 0)
Assert.eq(bb.pixels, 0, "mask=false 不画遮罩")
s, p = anchored{ x = 560, y = 760, w = 40, h = 40 }
Assert.eq(p.y + p.h, 760, "下方放不下：贴锚点上沿")
Assert.eq(p.x + p.w, 600 - 8, "右侧夹到 sm 边距")
Assert.is_true(s:onTapModal(nil, Kit.tap(p.x + 1, p.y + 1)))
Assert.is_false(Kit.closed[#Kit.closed] == s, "面板内点按不关")

-- 进度弹窗：有 total 才动进度条，done 夹到 total；只刷面板区域。
local progress = ProgressDialog:new{ title = "导入" }
progress:update("a.epub", 3, 12)
Assert.eq(progress.detail.text, "a.epub（3/12）")
Assert.eq(progress.bar.percent, 25)
progress:update("整理中")
Assert.eq(progress.detail.text, "整理中")
Assert.eq(progress.bar.percent, 25)
progress:update("b.epub", 20, 12)
Assert.eq(progress.bar.percent, 100)
local mode = Kit.dirty[#Kit.dirty].mode()
Assert.eq(mode, "fast")
Assert.len(Kit.buttons(progress), 0, "无回调不出按钮行")
-- 点按一律不关：面板内外都吞掉。
local progress_panel = paint(progress)
local progress_closed = #Kit.closed
Assert.is_true(progress:onTapModal(nil, Kit.tap(progress_panel.x + 1, progress_panel.y + 1)))
Assert.is_true(progress:onTapModal(nil, Kit.tap(1, 1)))
Assert.eq(#Kit.closed, progress_closed, "进度弹窗点按不关")
-- set：文案原样显示，percent 省略时进度条不动。
progress:set("1.0 / 4.0 MB", 25)
Assert.eq(progress.detail.text, "1.0 / 4.0 MB")
Assert.eq(progress.bar.percent, 25)
progress:set("拼接中")
Assert.eq(progress.bar.percent, 25)

-- 可转后台 / 可取消：出「取消」「后台运行」，点按不关；按钮先关窗再回调；返回键 = 后台运行。
log = {}
local bg
bg = ProgressDialog:new{
    title = "下载",
    on_background = function() log[#log + 1] = "bg:" .. tostring(Kit.closed[#Kit.closed] == bg) end,
    on_cancel = function() log[#log + 1] = "cancel:" .. tostring(Kit.closed[#Kit.closed] == bg) end,
}
buttons = Kit.buttons(bg)
Assert.len(buttons, 2)
Assert.eq(buttons[1].text, "取消")
Assert.eq(buttons[2].text, "后台运行")
Assert.eq(buttons[2].variant, "primary")
panel = paint(bg)
closed = #Kit.closed
Assert.is_true(bg:onTapModal(nil, Kit.tap(panel.x + 1, panel.y + 1)))
Assert.eq(#Kit.closed, closed, "面板内点按不关")
buttons[1]:onTapThemeButton()
Assert.eq(log[1], "cancel:true")
buttons[2]:onTapThemeButton()
Assert.eq(log[2], "bg:true")
closed = #Kit.closed
Assert.is_true(bg:onTapModal(nil, Kit.tap(1, 1)))
Assert.eq(#Kit.closed, closed, "面板外点按不关")
Assert.len(log, 2, "面板外点按不转后台")
Assert.is_true(bg:onClose())
Assert.eq(log[3], "bg:true")
-- dismissable = false：返回键也吞掉。
local locked = ProgressDialog:new{ title = "x", dismissable = false }
closed = #Kit.closed
Assert.is_true(locked:onClose())
Assert.eq(#Kit.closed, closed, "dismissable=false 返回键不关")
-- 只给 on_background：只有「后台运行」一个按钮。
Assert.len(Kit.buttons(ProgressDialog:new{ title = "x", on_background = function() end }), 1)

-- 二维码：边长取面板内宽与半屏高的较小值；任意点按收起。
local qr = QR:new{ title = "扫码", text = "https://ankio.net", caption = "用微信扫一扫" }
local code = Kit.find(qr, function(w) return w ~= qr and w.text == "https://ankio.net" end)[1]
Assert.eq(code.width, math.min(qr:innerWidth(), 400))
paint(qr)
qr:onTapModal(nil, Kit.tap(1, 1))
Assert.eq(Kit.closed[#Kit.closed], qr)

-- guard 隔离（错误页本身见 tests/ui/guard_spec.lua）：换记录桩后重载 Modal。
do
    local reported = {}
    package.loaded["ui.guard"] = {
        call = function(label, fn, ...)
            local res = { pcall(fn, ...) }
            if res[1] then return unpack(res, 2) end
            reported[#reported + 1] = label
        end,
    }
    package.loaded["ui.themes.widgets.modal"] = nil
    package.loaded["ui.themes.widgets.toast"] = nil
    local GuardedToast = require("ui.themes.widgets.toast")

    -- 正常：绘制与事件照旧（面板内点按 = close_on_tap 关窗，事件已处理）
    local ok_toast = GuardedToast:new{ text = "ok" }
    local ok_panel = paint(ok_toast)
    Assert.is_true(ok_toast:handleEvent({ handler = "onTapModal", args = { nil, Kit.tap(ok_panel.x + 1, ok_panel.y + 1) } }))
    Assert.eq(Kit.closed[#Kit.closed], ok_toast)
    Assert.len(reported, 0)

    -- 事件处理抛错：报告，并算已处理（不漏到下层窗口），窗口留着
    local bad_event = GuardedToast:new{ text = "x" }
    function bad_event:onTapModal() error("tap boom") end
    local closed_before = #Kit.closed
    Assert.is_true(bad_event:handleEvent({ handler = "onTapModal", args = { nil, Kit.tap(1, 1) } }))
    Assert.eq(reported[1], "modal onTapModal")
    Assert.eq(#Kit.closed, closed_before)

    -- UIManager.__default__ 原样转发的原始输入（模拟器电源键）不是 Event：不消费、不报错
    Assert.is_nil(GuardedToast:new{ text = "raw" }:handleEvent("PowerRelease"))
    Assert.len(reported, 1)

    -- 绘制抛错：报告一次并关窗；关窗前的重绘不再画、不再报
    local bad_paint = GuardedToast:new{ text = "x" }
    bad_paint[1] = { paintTo = function() error("paint boom") end }
    bad_paint.panel_x, bad_paint.panel_y = 0, 0
    bad_paint:paintTo(Kit.canvas(), 0, 0)
    Assert.eq(reported[2], "modal paint")
    Assert.eq(Kit.closed[#Kit.closed], bad_paint, "画坏的弹窗被关掉，不留隐形窗口吞点按")
    bad_paint:paintTo(Kit.canvas(), 0, 0)
    Assert.len(reported, 2)
end

return true
