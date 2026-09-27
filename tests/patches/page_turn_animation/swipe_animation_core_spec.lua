--[[--
翻页动画运行时补丁：各风格的帧几何与播放循环。

墨水屏约束即测试不变量：所有帧的矩形恰好铺满整屏且互不重叠（每个像素只刷一次），
内部边界按 alignment_constraint 对齐，不出现驱动会丢弃的 ≤1px 细条，帧数与刷新块数有上限。

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
    local bb = { blits = {} }
    function bb.getWidth() return w end
    function bb.getHeight() return h end
    function bb.copy() return newBB(w, h) end
    function bb.free() end
    function bb.blitFrom(self, src, dx, dy, sx, sy, bw, bh)
        self.blits[#self.blits + 1] = { src = src, dx = dx, dy = dy, sx = sx, sy = sy, w = bw, h = bh }
    end
    return bb
end

local Screen = { refreshes = {} }
local function recorder(kind)
    return function(self, x, y, w, h)
        self.refreshes[#self.refreshes + 1] = { kind = kind, x = x, y = y, w = w, h = h }
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
local S = SwipeAnimation.STYLES

local NAMES = { "wipe", "wipe_vertical", "split", "blinds", "random_bars", "box" }

--- 每个风格都必须恰好铺满整屏、互不重叠、边界对齐、不超预算。
local function assertPartition(frames, w, h, steps, align, label)
    Assert.is_true(#frames > 0 and #frames <= steps, label .. " 帧数在 1..steps")
    local rects, area = {}, 0
    for _, frame in ipairs(frames) do
        Assert.is_true(#frame > 0, label .. " 无空帧")
        for _, r in ipairs(frame) do
            local x, y, rw, rh = r[1], r[2], r[3], r[4]
            Assert.is_true(rw > 1 and rh > 1, label .. " 无细条")
            Assert.is_true(x >= 0 and y >= 0 and x + rw <= w and y + rh <= h, label .. " 不越界")
            if align then
                for _, e in ipairs({ x, x + rw }) do
                    Assert.is_true(e == w or e % align == 0, label .. " x 边界对齐")
                end
                for _, e in ipairs({ y, y + rh }) do
                    Assert.is_true(e == h or e % align == 0, label .. " y 边界对齐")
                end
            end
            for _, o in ipairs(rects) do
                local disjoint = x + rw <= o[1] or o[1] + o[3] <= x or y + rh <= o[2] or o[2] + o[4] <= y
                Assert.is_true(disjoint, label .. " 互不重叠")
            end
            rects[#rects + 1] = r
            area = area + rw * rh
        end
    end
    Assert.eq(area, w * h, label .. " 铺满整屏")
    Assert.is_true(#rects <= 2 * steps, label .. " 刷新块数不超预算")
end

local SCREENS = {
    { 1072, 1448, 8, 16 },   -- Kobo MTK 竖屏
    { 1448, 1072, 6, 16 },   -- 横屏
    { 1264, 1680, 8, 16 },
    { 758, 1024, 8, nil },   -- 无对齐约束
}
for _, sc in ipairs(SCREENS) do
    local w, h, steps, align = sc[1], sc[2], sc[3], sc[4]
    for _, name in ipairs(NAMES) do
        for _, forward in ipairs({ true, false }) do
            local label = ("%s %dx%d fwd=%s"):format(name, w, h, tostring(forward))
            assertPartition(S[name](w, h, steps, align, forward), w, h, steps, align, label)
        end
    end
end

local W, H, STEPS, ALIGN = 1072, 1448, 8, 16
local function first(name, forward) return S[name](W, H, STEPS, ALIGN, forward)[1] end
local function touches(frame, pred)
    for _, r in ipairs(frame) do
        if pred(r) then return true end
    end
    return false
end

-- 擦除：向前翻从右往左，向后翻从左往右（与旧实现一致）。
Assert.is_true(touches(first("wipe", true), function(r) return r[1] + r[3] == W end))
Assert.is_true(touches(first("wipe", false), function(r) return r[1] == 0 end))
-- 纵向擦除：向前翻自上而下，向后翻自下而上。
Assert.is_true(touches(first("wipe_vertical", true), function(r) return r[2] == 0 end))
Assert.is_true(touches(first("wipe_vertical", false), function(r) return r[2] + r[4] == H end))
-- 分割：向前翻从中线展开，向后翻从两侧合拢。
Assert.is_true(touches(first("split", true), function(r) return r[1] <= W / 2 and W / 2 < r[1] + r[3] end))
Assert.is_true(touches(first("split", false), function(r) return r[1] == 0 end))
Assert.is_true(touches(first("split", false), function(r) return r[1] + r[3] == W end))
-- 百叶窗：每帧 4 组同时揭。
Assert.len(first("blinds", true), 4)
-- 方框：向前翻首帧包含屏幕中心，向后翻首帧是最外圈。
Assert.is_true(touches(first("box", true), function(r)
    return r[1] <= W / 2 and W / 2 < r[1] + r[3] and r[2] <= H / 2 and H / 2 < r[2] + r[4]
end))
Assert.is_true(touches(first("box", false), function(r) return r[1] == 0 and r[2] == 0 end))

-- 边界：屏宽不足以切满条带时帧数跟着缩，不出现空帧。
assertPartition(S.wipe(W, H, 200, 16, true), W, H, 200, 16, "wipe narrow")
Assert.len(S.wipe(W, H, 200, 16, true), 67)

--- 以给定风格跑一次动画，返回屏幕刷新记录。
---@param style string|nil
---@param ui table|nil UIManager 实例替身，缺省不清屏
---@param no_snapshot boolean|nil 模拟 beforePaint 没拍到旧页
local function run(style, ui, no_snapshot)
    store.swipe_animation_style = style
    store.swipe_animation_delay_ms = 0
    Screen.bb = newBB(W, H)
    Screen.saved_bb = not no_snapshot and newBB(W, H) or nil
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

-- 播放：blit 与刷新同一块区域，且只从新页原位取图（揭开，不搬移内容）。
local refreshes, blits = run("box")
Assert.len(blits, #refreshes + 1, "第 1 次 blit 是旧页打底，其后每块一次")
for i, r in ipairs(refreshes) do
    local b = blits[i + 1]
    Assert.eq(b.dx, r.x) Assert.eq(b.dy, r.y) Assert.eq(b.w, r.w) Assert.eq(b.h, r.h)
    Assert.eq(b.sx, b.dx) Assert.eq(b.sy, b.dy)
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
Assert.eq(kinds((run("split", every_three))), "ui,ui,ui,ui,ui,ui,ui,ui")
Assert.eq(kinds((run("split", every_three))), "ui,ui,ui,ui,ui,ui,ui,ui")
Assert.eq(kinds((run("split", every_three))), "ui,ui,ui,ui,ui,ui,ui,ui,full")
Assert.eq(kinds((run("split", every_three))), "ui,ui,ui,ui,ui,ui,ui,ui")

-- 柔和全刷设置：补的是整屏 partial 而不是闪屏 full。
store.swipe_animation_mild_global_refresh = true
refreshes = run("wipe_vertical", { FULL_REFRESH_COUNT = 1 })
Assert.eq(refreshes[#refreshes].kind, "partial")
Assert.len(refreshes, STEPS + 1)
store.swipe_animation_mild_global_refresh = nil

-- 没拍到旧页：不播动画，只做清屏；不清屏时排队刷新原样保留。
local r, _, ui = run("wipe", { FULL_REFRESH_COUNT = 1 }, true)
Assert.eq(kinds(r), "full")
Assert.len(ui._refresh_stack, 0)
r, _, ui = run("wipe", nil, true)
Assert.len(r, 0)
Assert.len(ui._refresh_stack, 1)

-- 未知 / 未设置 / 已删除的旧风格值回退擦除
for _, style in ipairs({ "nope", "cover", "center" }) do
    refreshes = run(style)
    Assert.len(refreshes, STEPS)
    Assert.eq(refreshes[1].x + refreshes[1].w, W)
end
Assert.len((run(nil)), STEPS)

return true
