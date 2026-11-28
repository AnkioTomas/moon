--[[--
纯按键焦点收集器 ui.focus：把绘制后的 widget 树收成一条线性链。
- 扁平、按 (y, x) 阅读顺序排；
- 遇到可点控件即收、不再下探；禁用按钮 / 无 dimen 跳过；空树返回 nil；
- activate 调对应 tap 回调。

@module tests.ui.focus_spec
--]]

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")

local Focus = require("ui.focus")

-- enabled()：有方向键且没有触摸才生效
Kit.has_dpad, Kit.touch = true, false
Assert.is_true(Focus.enabled(), "方向键 + 无触摸")
Kit.touch = true
Assert.is_true(not Focus.enabled(), "触屏即便有方向键也不启用")
Kit.has_dpad, Kit.touch = false, false
Assert.is_true(not Focus.enabled(), "无方向键不启用")
Kit.has_dpad, Kit.touch = false, nil

local function area(x, y, w, h, inner)
    local t = { onTapThemeArea = function() end, dimen = { x = x, y = y, w = w, h = h } }
    if inner then t[1] = inner end
    return t
end
local function group(...) return { ... } end

-- 扁平、按 (y, x) 排：同一行先排 x 小的，再下一行
local flat = Focus.list(group(area(100, 0, 50, 40), area(0, 0, 50, 40), area(0, 100, 50, 40)))
Assert.len(flat, 3)
Assert.eq(flat[1].dimen.x, 0, "同一行先取 x 小的")
Assert.eq(flat[2].dimen.x, 100)
Assert.eq(flat[3].dimen.y, 100, "再下一行")

-- 遇到可点即停，不收它内部的次级控件
local nested = Focus.list(group(area(0, 0, 100, 40, area(0, 0, 20, 20))))
Assert.len(nested, 1, "外层点击区收下，内部不再单独成焦点")

-- 禁用按钮、无 dimen 控件跳过；全跳过则 nil
Assert.is_nil(Focus.list(group(
    { onTapThemeButton = function() end, enabled = false, dimen = { x = 0, y = 0, w = 10, h = 10 } },
    { onTapThemeArea = function() end }
)), "禁用 + 无坐标 → 没有可点控件")

-- 空树 nil
Assert.is_nil(Focus.list(group(group(), { dimen = { x = 0, y = 0, w = 1, h = 1 } })))

-- activate 按标记调对应回调
local hit
Focus.activate({ onTapThemeButton = function() hit = "btn" end })
Assert.eq(hit, "btn")
Focus.activate({ onTapBookInfo = function() hit = "book" end })
Assert.eq(hit, "book")
Focus.activate({ onTapThemeArea = function() hit = "area" end })
Assert.eq(hit, "area")

-- moveDir：按方向跳到该方向最近控件，只刷旧框∪新框
-- 布局：0=上(0,0) 1=下左(0,100) 2=下右(40,100)
local mh = { _focus_list = { area(0, 0, 10, 10), area(0, 100, 20, 10), area(40, 100, 20, 10) }, _focus_idx = 1 }
Kit.dirty = {}
Focus.moveDir(mh, "down")
Assert.eq(mh._focus_idx, 2, "下键跳到下方最近项")
local mode, region = Kit.dirty[1].mode()
Assert.eq(mode, "ui")
Assert.eq(region.w, 20, "外包框宽")
Assert.eq(region.h, 110, "外包框高")
Focus.moveDir(mh, "right")
Assert.eq(mh._focus_idx, 3, "右键跳到右侧项")
Focus.moveDir(mh, "up")
Assert.eq(mh._focus_idx, 1, "上键回上方项")
-- 该方向没有控件不动、不刷
Kit.dirty = {}
Focus.moveDir(mh, "up")
Assert.eq(mh._focus_idx, 1, "上方无控件夹住")
Assert.len(Kit.dirty, 0, "不动不刷")
-- 没有链（还没绘制）不动
local fresh = {}
Assert.is_true(Focus.moveDir(fresh, "down"))
Assert.is_nil(fresh._focus_idx)

-- hold：在焦点项中心往宿主控件树发 hold 手势，返回是否被接住；没有焦点项不发
local got, got_host, handled
package.loaded["ui/widget/container/inputcontainer"] = {
    handleEvent = function(h, ev) got_host, got = h, ev return handled end,
}
local host = {}
host._focus_list, host._focus_idx = { area(10, 20, 100, 41) }, 1
handled = true
Assert.is_true(Focus.hold(host))
Assert.eq(got_host, host)
local ges = got.args[1]
Assert.eq(got.handler, "onGesture")
Assert.eq(ges.ges, "hold")
Assert.eq(ges.pos.x, 60)
Assert.eq(ges.pos.y, 40)
handled = nil
Assert.is_nil(Focus.hold(host), "没人接住返回假")
got = nil
host._focus_list = nil
Assert.is_nil(Focus.hold(host))
Assert.is_nil(got, "没有焦点项不发手势")

return true
