--[[--
翻页动画运行时补丁：各风格的帧几何与播放循环。

@module tests.patches.page_turn_animation.swipe_animation_core_spec
--]]

local Assert = require("support.assert")
local Config = require("support.config")

local store = {}
_G.G_reader_settings = {
    isTrue = function(_, key) return store[key] == true end,
    readSetting = function(_, key) return store[key] end,
}

local function newBB(w, h)
    local bb = { w = w, h = h, blits = {} }
    function bb.getWidth() return w end
    function bb.getHeight() return h end
    function bb.copy() return newBB(w, h) end
    function bb.free() end
    function bb.blitFrom(self, src, dx, dy, sx, sy, bw, bh)
        self.blits[#self.blits + 1] = { src = src, dx = dx, sx = sx, w = bw, h = bh }
    end
    return bb
end

local Screen = { refreshes = {} }
local function recorder(kind)
    return function(self, x, y, w, h)
        self.refreshes[#self.refreshes + 1] = { kind = kind, x = x, w = w, h = h }
    end
end
Screen.refreshUI = recorder("ui")
Screen.refreshFast = recorder("fast")
Screen.refreshFull = recorder("full")
Screen.refreshPartial = recorder("partial")

package.loaded["device"] = { screen = Screen, isKobo = function() return false end }
package.loaded["logger"] = { dbg = function() end, warn = function(...) error(table.concat({ ... }, " ")) end }
package.loaded["apps/reader/readerui"] = {}
package.loaded["ui/uimanager"] = {}

-- KOReader 里 usleep 由 ffi/posix_h 声明；同进程其他 spec 可能已声明过，重复 cdef 会报错。
local ffi = require("ffi")
if not pcall(function() return ffi.C.usleep end) then
    ffi.cdef("int usleep(unsigned int);")
end

dofile(Config.root() .. "/book.koplugin/patches/page_turn_animation/2-swipe-animation-core.lua")
local SwipeAnimation = _G.SwipeAnimation
_G.SwipeAnimation = nil
Assert.is_true(type(SwipeAnimation) == "table", "补丁加载失败")

local W, STEPS, ALIGN = 1072, 8, 16

--- 揭开类风格：所有帧的矩形不重叠、src==dst，拼起来正好覆盖整屏宽度。
local function assertReveal(frames, label)
    local covered = {}
    for _, frame in ipairs(frames) do
        Assert.is_true(#frame > 0, label .. " 空帧")
        for _, r in ipairs(frame) do
            Assert.eq(r[1], r[2], label .. " src==dst")
            Assert.is_true(r[3] > 0, label .. " 宽度为正")
            covered[#covered + 1] = r
        end
    end
    table.sort(covered, function(a, b) return a[1] < b[1] end)
    local x = 0
    for _, r in ipairs(covered) do
        Assert.eq(r[1], x, label .. " 无缝无重叠")
        x = r[1] + r[3]
    end
    Assert.eq(x, W, label .. " 覆盖整屏")
end

local S = SwipeAnimation.STYLES
for _, forward in ipairs({ true, false }) do
    local wipe = S.wipe(W, STEPS, ALIGN, forward)
    assertReveal(wipe, "wipe")
    Assert.len(wipe, STEPS)
    -- 向前翻从右往左揭，向后翻从左往右揭（与旧实现一致）
    Assert.eq(wipe[1][1][1] + wipe[1][1][3] == W, forward)
    Assert.eq(wipe[1][1][1] == 0, not forward)

    local blinds = S.blinds(W, STEPS, ALIGN, forward)
    assertReveal(blinds, "blinds")
    Assert.len(blinds, STEPS)
    Assert.len(blinds[1], 4)

    local center = S.center(W, STEPS, ALIGN, forward)
    assertReveal(center, "center")
    Assert.len(center, STEPS / 2)
    local first = center[1]
    if forward then
        Assert.eq(first[1][1] + first[1][3], first[2][1], "中心展开首帧两条相邻")
    else
        Assert.eq(first[1][1], 0, "向后翻从两边开始")
    end

    local cover = S.cover(W, STEPS, ALIGN, forward)
    Assert.len(cover, STEPS)
    local prev_w = 0
    for _, frame in ipairs(cover) do
        local r = frame[1]
        Assert.len(frame, 1)
        Assert.is_true(r[3] > prev_w, "覆盖帧逐步变宽")
        prev_w = r[3]
        if forward then
            Assert.eq(r[1] + r[3], W, "向前翻贴右边")
            Assert.eq(r[2], 0, "新页左缘先入场")
        else
            Assert.eq(r[1], 0, "向后翻贴左边")
            Assert.eq(r[2] + r[3], W, "新页右缘先入场")
        end
    end
    Assert.eq(prev_w, W, "最后一帧整屏")
end

-- 边界：屏宽不足以切满条带时帧数跟着缩，不出现空帧。
assertReveal(S.wipe(W, 200, 16, true), "wipe narrow")
Assert.len(S.wipe(W, 200, 16, true), 67)

--- 以给定风格跑一次动画，返回屏幕刷新记录。
---@param style string|nil
---@param ui table|nil UIManager 实例替身，缺省不清屏
---@param no_snapshot boolean|nil 模拟 beforePaint 没拍到旧页
local function run(style, ui, no_snapshot)
    store.swipe_animation_style = style
    store.swipe_animation_delay_ms = 0
    Screen.bb = newBB(W, 1448)
    Screen.saved_bb = not no_snapshot and newBB(W, 1448) or nil
    Screen.swipe_forward = true
    Screen.refreshes = {}
    ui = ui or { FULL_REFRESH_COUNT = 0 }
    ui._refresh_stack = { "queued" }
    SwipeAnimation.runSwipeAnimation(ui)
    Assert.is_nil(Screen.saved_bb, "快照被消费")
    return Screen.refreshes, Screen.bb.blits, ui
end

local function kinds(refreshes)
    local out = {}
    for _, r in ipairs(refreshes) do out[#out + 1] = r.kind end
    return table.concat(out, ",")
end

-- 每页全刷：每一页都照播动画，播完补一次整屏全刷（回归：以前清屏页整页跳过动画）。
local every_page = { FULL_REFRESH_COUNT = 1 }
for _ = 1, 3 do
    local r, _, ui = run("wipe", every_page)
    Assert.eq(kinds(r), "ui,ui,ui,ui,ui,ui,ui,ui,full")
    Assert.eq(r[#r].w, W)
    Assert.len(ui._refresh_stack, 0)
end

-- 每 3 页全刷：只有第 3 页在动画后补全刷，前两页只有动画。
local every_three = { FULL_REFRESH_COUNT = 3 }
Assert.eq(kinds((run("center", every_three))), "ui,ui,ui,ui,ui,ui,ui,ui")
Assert.eq(kinds((run("center", every_three))), "ui,ui,ui,ui,ui,ui,ui,ui")
Assert.eq(kinds((run("center", every_three))), "ui,ui,ui,ui,ui,ui,ui,ui,full")
Assert.eq(kinds((run("center", every_three))), "ui,ui,ui,ui,ui,ui,ui,ui")

-- 柔和全刷设置：补的是整屏 partial 而不是闪屏 full。
store.swipe_animation_mild_global_refresh = true
Assert.eq(kinds((run("cover", { FULL_REFRESH_COUNT = 1 }))), "ui,ui,ui,ui,ui,ui,ui,ui,partial")
store.swipe_animation_mild_global_refresh = nil

-- 没拍到旧页：不播动画，只做清屏；不清屏时排队刷新原样保留。
local r, _, ui = run("wipe", { FULL_REFRESH_COUNT = 1 }, true)
Assert.eq(kinds(r), "full")
Assert.len(ui._refresh_stack, 0)
r, _, ui = run("wipe", nil, true)
Assert.len(r, 0)
Assert.len(ui._refresh_stack, 1)

local refreshes, blits = run("cover")
Assert.len(refreshes, STEPS)
Assert.eq(refreshes[#refreshes].x, 0)
Assert.eq(refreshes[#refreshes].w, W)
-- 第 1 次 blit 是旧页打底，其后每帧一次
Assert.len(blits, STEPS + 1)
Assert.eq(blits[2].sx, 0)

-- 未知 / 未设置风格回退擦除
refreshes = run("nope")
Assert.len(refreshes, STEPS)
Assert.eq(refreshes[1].x + refreshes[1].w, W)
refreshes = run(nil)
Assert.len(refreshes, STEPS)

return true
