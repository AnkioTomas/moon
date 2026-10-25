--[[--
features.passcode.pattern：划过的点序号成串、点不重复、不足 4 点拒绝、抬手才提交、起点不在点上忽略。
@module tests.features.passcode.pattern_spec
--]]

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")

local Pattern = require("features.passcode.pattern")
local Modal = require("ui.themes.widgets.modal")

local submitted = {}
local reply = "密码错误" ---@type string|true
local pat = Pattern:new{
    title = "绘制手势解锁",
    dismissable = false,
    on_submit = function(seq)
        submitted[#submitted + 1] = seq
        return reply
    end,
}
local grid = pat.grid

local canvas = Kit.canvas()
local circles = 0
canvas.paintCircle = function() circles = circles + 1 end
canvas.paintRect = function() end
Assert.eq(pat.paintTo, Modal.paintTo)
Assert.eq(pat.handleEvent, Modal.handleEvent)
pat:paintTo(canvas, 0, 0)
Assert.eq(circles, 18, "九个圆环通过 Modal 的绘制入口画出")

--- 点 n 的屏幕坐标。
local function at(n)
    local cx, cy = grid:center(n)
    return Kit.tap(grid.dimen.x + cx, grid.dimen.y + cy)
end

local function gesture(name, ges)
    ges.ges = name
    for event, ranges in pairs(pat.ges_events) do
        for _idx, range in ipairs(ranges) do
            if range.ges == name then
                return pat:handleEvent({ handler = "on" .. event, args = { nil, ges } })
            end
        end
    end
    error("未注册的手势：" .. name)
end

--- 依次划过这些点后抬手。
local function draw(...)
    local pts = { ... }
    gesture("touch", at(pts[1]))
    for i = 2, #pts do gesture("pan", at(pts[i])) end
    gesture("pan_release", at(pts[#pts]))
end

draw(1, 5, 9, 6)
Assert.eq(submitted[1], "1596")
Assert.contains(Kit.texts(pat), "密码错误")
Assert.len(grid.seq, 0, "提交被拒后清空")

-- 重复经过的点不重复记。
draw(1, 2, 1, 2, 3, 6)
Assert.eq(submitted[2], "1236")

-- 不足 4 点不提交，只提示。
draw(1, 2, 3)
Assert.len(submitted, 2)
Assert.contains(Kit.texts(pat), "至少连接 4 个点")

-- 起点不在点上：整次划动忽略。
gesture("touch", Kit.tap(0, 0))
gesture("pan", at(1))
gesture("pan_release", at(1))
Assert.len(submitted, 2)

-- 快速划过时补中点，最后一个点只在松手事件里出现也不会丢。
gesture("touch", at(1))
gesture("pan", at(3))
gesture("pan_release", at(9))
Assert.eq(submitted[3], "12369")

-- KOReader 快划结束发 swipe / multiswipe，不发 pan_release；pos 是起点，end_pos 才是终点。
for _idx, name in ipairs({ "swipe", "multiswipe" }) do
    gesture("touch", at(1))
    gesture("pan", at(3))
    local release = at(1)
    release.end_pos = at(9).pos
    gesture(name, release)
    Assert.eq(submitted[#submitted], "12369")
end

-- 起点长按后再画，事件变成 hold_pan / hold_release。
gesture("touch", at(7))
gesture("hold_pan", at(9))
gesture("hold_release", at(3))
Assert.eq(submitted[#submitted], "78963")

local count = #submitted
gesture("touch", at(1))
gesture("tap", at(1))
Assert.is_false(pat.touching)
Assert.len(submitted, count)

-- 点阵空隙不是点；在已选点之间移动不重绘。
local x1, y1 = grid:center(1)
local x2 = grid:center(2)
Assert.is_nil(grid:hit(Kit.tap(grid.dimen.x + (x1 + x2) / 2, grid.dimen.y + y1).pos))
gesture("touch", at(1))
local dirty = #Kit.dirty
gesture("pan", at(1))
Assert.eq(#Kit.dirty, dirty)
pat:clear()
Assert.is_false(pat.touching)
Assert.len(grid.seq, 0)

-- 画出连线也能正常走 Modal，唤醒后清空。
gesture("touch", at(1))
gesture("pan", at(9))
pat:paintTo(canvas, 0, 0)
pat:clear()

-- 通过返回 true：关窗。
reply = true
draw(7, 8, 9, 6)
Assert.eq(submitted[#submitted], "7896")
Assert.eq(Kit.closed[#Kit.closed], pat)
