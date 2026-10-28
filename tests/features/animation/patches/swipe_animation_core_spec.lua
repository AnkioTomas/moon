--[[--
翻页动画运行时补丁：各风格的帧几何与播放循环。

墨水屏约束即测试不变量：所有帧的矩形恰好铺满整屏且互不重叠（每个像素只刷一次），
内部边界按 alignment_constraint 对齐，不出现驱动会丢弃的 ≤1px 细条，帧数与刷新块数有上限。

@module tests.features.animation.patches.swipe_animation_core_spec
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
    bb.paints = {}
    function bb.paintRect(self, x, y, pw, ph, color)
        self.paints[#self.paints + 1] = { x = x, y = y, w = pw, h = ph, color = color }
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

local Device = {
    screen = Screen,
    _kobo = false,
    _color = false,
    _mtk = false,
    isKobo = function(self) return self._kobo end,
    hasColorScreen = function(self) return self._color end,
    isMTK = function(self) return self._mtk end,
}
package.loaded["device"] = Device
package.loaded["logger"] = { dbg = function() end, warn = function(...) error(table.concat({ ... }, " ")) end }
local BB = {
    COLOR_LIGHT_GRAY = "gray_c", COLOR_GRAY_9 = "gray_9", COLOR_GRAY_7 = "gray_7", COLOR_GRAY_4 = "gray_4",
}
package.loaded["ffi/blitbuffer"] = BB

local sleeps = {}
package.loaded["ffi"] = { C = {
    usleep = function(usec) sleeps[#sleeps + 1] = usec end,
} }

dofile(Config.root() .. "/book.koplugin/features/animation/patches/2-swipe-animation-core.lua")
local SwipeAnimation = _G.SwipeAnimation
_G.SwipeAnimation = nil
Assert.is_true(type(SwipeAnimation) == "table", "补丁加载失败")
local S = SwipeAnimation.STYLES

local NAMES = {
    "wipe", "shadow", "wipe_vertical", "diagonal", "split", "blinds", "comb", "random_bars",
    "box", "spiral", "clock", "typewriter", "checkerboard", "random_blocks",
}

local function contains(o, r)
    return o[1] <= r[1] and r[1] + r[3] <= o[1] + o[3] and o[2] <= r[2] and r[2] + r[4] <= o[2] + o[4]
end

--- 每个风格都必须恰好铺满整屏、互不重叠、边界对齐、不超预算。
--- fill（阴影）不参与铺满，但必须被之后某一帧的揭开块完全盖住，不留残影。
local function assertPartition(frames, w, h, steps, align, label)
    Assert.is_true(#frames > 0 and #frames <= steps, label .. " 帧数在 1..steps")
    local reveals, fills = {}, {}
    for fi, frame in ipairs(frames) do
        Assert.is_true(#frame > 0, label .. " 无空帧")
        for _, r in ipairs(frame) do
            local list = r[5] and fills or reveals
            list[#list + 1] = { rect = r, frame = fi }
        end
    end
    Assert.is_true(#reveals + #fills <= 2 * steps, label .. " 刷新块数不超预算")

    local area = 0
    for i, item in ipairs(reveals) do
        local x, y, rw, rh = unpack(item.rect)
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
        for j = 1, i - 1 do
            local o = reveals[j].rect
            local disjoint = x + rw <= o[1] or o[1] + o[3] <= x or y + rh <= o[2] or o[2] + o[4] <= y
            Assert.is_true(disjoint, label .. " 互不重叠")
        end
        area = area + rw * rh
    end
    Assert.eq(area, w * h, label .. " 铺满整屏")

    for _, fill in ipairs(fills) do
        local covered = false
        for _, item in ipairs(reveals) do
            if item.frame > fill.frame and contains(item.rect, fill.rect) then covered = true end
        end
        Assert.is_true(covered, label .. " 阴影被后续帧盖住")
    end
end

local SCREENS = {
    { 1072, 1448, 8, 16 },   -- Kobo MTK 竖屏
    { 1448, 1072, 6, 16 },   -- 横屏
    { 1264, 1680, 8, 16 },   -- Libra Colour 分辨率，灰度路径仍对齐
    { 1264, 1680, 8, nil },  -- 同分辨率不对齐（Kobo 彩屏 strip_align=nil）
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

local function at(x, y) return function(r) return r[1] == x and r[2] == y end end
local function hasBottomRight(r) return r[1] + r[3] == W and r[2] + r[4] == H end
local function last(name, forward)
    local frames = S[name](W, H, STEPS, ALIGN, forward)
    return frames[#frames]
end

-- 时钟：四拍各一个象限，向前翻从右上（12 点右侧）顺时针，向后翻从左上逆时针。
Assert.len(S.clock(W, H, STEPS, ALIGN, true), 4)
Assert.is_true(touches(first("clock", true), function(r) return r[1] > 0 and r[2] == 0 end))
Assert.is_true(touches(S.clock(W, H, STEPS, ALIGN, true)[2], hasBottomRight))
Assert.is_true(touches(first("clock", false), at(0, 0)))
-- 逐行：向前翻从左上开始，向后翻从右下开始。
Assert.is_true(touches(first("typewriter", true), at(0, 0)))
Assert.is_true(touches(first("typewriter", false), hasBottomRight))
-- 螺旋：向前翻从外圈左上旋入、最后一帧在中心，向后翻反过来。
Assert.is_true(touches(first("spiral", true), at(0, 0)))
Assert.is_true(touches(last("spiral", false), at(0, 0)))
for _, r in ipairs(last("spiral", true)) do
    Assert.is_true(r[1] > 0 and r[2] > 0 and r[1] + r[3] < W and r[2] + r[4] < H, "螺旋终点在内圈")
end
-- 棋盘：两拍，互为补集，向后翻两拍互换。
Assert.len(S.checkerboard(W, H, STEPS, ALIGN, true), 2)
Assert.is_true(touches(first("checkerboard", true), at(0, 0)))
Assert.is_false(touches(first("checkerboard", false), at(0, 0)))
-- 梳状：每帧每条横带一格，相邻横带方向相反。
local comb = first("comb", true)
Assert.len(comb, 4)
Assert.eq(comb[1][1] + comb[1][3], W, "向前翻第一带从右侧入")
Assert.eq(comb[2][1], 0, "第二带从左侧入")
-- 斜向擦除：向前翻从右上角开始，向后翻从左上角开始；首帧只有角上一格。
Assert.len(first("diagonal", true), 1)
Assert.is_true(touches(first("diagonal", true), function(r) return r[1] + r[3] == W and r[2] == 0 end))
Assert.is_true(touches(first("diagonal", false), at(0, 0)))
Assert.len(S.diagonal(W, H, STEPS, ALIGN, true), 7)

-- 翻页阴影：阴影紧贴擦除前沿、落在旧页一侧，最深的一带挨着前沿；最后一帧无阴影。
for _, forward in ipairs({ true, false }) do
    local frames = S.shadow(W, H, STEPS, ALIGN, forward)
    Assert.len(frames, STEPS)
    for i, f in ipairs(frames) do
        local reveal, shade = f[1], f[2]
        if i == #frames then
            Assert.is_nil(shade, "最后一帧无阴影")
        elseif forward then
            Assert.eq(shade[1] + shade[3], reveal[1], "阴影贴在揭开区左侧")
            Assert.eq(shade[5][#shade[5]], BB.COLOR_GRAY_4, "最深色挨着前沿")
        else
            Assert.eq(shade[1], reveal[1] + reveal[3], "阴影贴在揭开区右侧")
            Assert.eq(shade[5][1], BB.COLOR_GRAY_4, "最深色挨着前沿")
        end
    end
end

-- 边界：屏宽不足以切满条带时帧数跟着缩，不出现空帧。
assertPartition(S.wipe(W, H, 200, 16, true), W, H, 200, 16, "wipe narrow")
Assert.len(S.wipe(W, H, 200, 16, true), 67)

--- 以给定风格跑一次动画，返回屏幕刷新记录。
---@param style string|nil
---@param stack table[]|nil 本轮 KOReader 排队的刷新，缺省只有一条 partial
---@param no_snapshot boolean|nil 模拟 beforePaint 没拍到旧页
local function run(style, stack, no_snapshot, w, h)
    store.swipe_animation_style = style
    store.swipe_animation_delay_ms = 0
    Screen.bb = newBB(w or W, h or H)
    Screen.saved_bb = not no_snapshot and newBB(w or W, h or H) or nil
    Screen.swipe_forward = true
    Screen.refreshes = {}
    local ui = { _refresh_stack = stack or { { mode = "partial" } } }
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

-- Kobo 彩屏：即使驱动 alignment_constraint=16，动画层也必须走不对齐切点
-- （1264/8 → 158，不是 160），让 getBoundedRect 扩边后条带边缘重叠盖住 CFA 缝。
-- 灰度 Kobo 仍按 16 对齐。不打开 isMTK，避免首条 strip 前的 fence 刷新干扰几何断言。
Screen.alignment_constraint = 16
Device._kobo, Device._color = true, true
refreshes = run("wipe", nil, nil, 1264, 1680)
Assert.eq(refreshes[1].w, 158, "Kobo 彩屏 wipe 首条不对齐")
Assert.eq(refreshes[1].x + refreshes[1].w, 1264)
Device._color = false
refreshes = run("wipe", nil, nil, 1264, 1680)
Assert.eq(refreshes[1].w, 160, "Kobo 灰度 wipe 仍按 16 对齐")
Device._kobo, Device._color = false, false
Screen.alignment_constraint = nil

-- 播放阴影：阴影块涂 4 级灰阶等宽竖带、不从新页取图，但同样刷新。
refreshes = run("shadow")
local bb = Screen.bb
Assert.len(refreshes, STEPS * 2 - 1)
Assert.len(bb.blits, STEPS + 1, "只有揭开块 blit")
Assert.len(bb.paints, (STEPS - 1) * 4)
local p = bb.paints
Assert.eq(p[1].w, 4) Assert.eq(p[1].h, H)
Assert.eq(p[2].x, p[1].x + 4)
Assert.eq(p[4].color, BB.COLOR_GRAY_4)
Assert.eq(p[4].x + p[4].w, refreshes[1].x, "向前翻阴影贴在第一条揭开区左侧")
Assert.eq(refreshes[2].x, p[1].x) Assert.eq(refreshes[2].w, 16)

-- KOReader 本轮排了全刷（每 N 页 / 章节边界 / 图片页）：照播动画，播完补一次整屏全刷，队列清空。
local r, _blits, ui = run("wipe", { { mode = "partial" }, { mode = "full" } })
Assert.eq(kinds(r), "ui,ui,ui,ui,ui,ui,ui,ui,full")
Assert.eq(r[#r].w, W)
Assert.len(ui._refresh_stack, 0)

-- 只有普通排队刷新：只播动画不补全刷；揭开已覆盖整屏，排队刷新丢弃。
r, _blits, ui = run("split")
Assert.eq(kinds(r), "ui,ui,ui,ui,ui,ui,ui,ui")
Assert.len(ui._refresh_stack, 0)

-- 柔和全刷设置：补的是整屏 partial 而不是闪屏 full。
store.swipe_animation_mild_global_refresh = true
refreshes = run("wipe_vertical", { { mode = "full" } })
Assert.eq(refreshes[#refreshes].kind, "partial")
Assert.len(refreshes, STEPS + 1)
store.swipe_animation_mild_global_refresh = nil

-- 没拍到旧页：不播动画、不刷新，排队刷新（含全刷）原样交回 KOReader 执行。
r, _blits, ui = run("wipe", { { mode = "full" } }, true)
Assert.len(r, 0)
Assert.len(ui._refresh_stack, 1)

-- 未知 / 未设置 / 已删除的旧风格值回退擦除
for _, style in ipairs({ "nope", "cover", "center" }) do
    refreshes = run(style)
    Assert.len(refreshes, STEPS)
    Assert.eq(refreshes[1].x + refreshes[1].w, W)
end
Assert.len((run(nil)), STEPS)

-- 速度每次翻页读取；只调整帧间隔，不改变帧数和刷新几何。横屏保持原来的半间隔。
for _, screen in ipairs({ { W, H, 8, 20 }, { H, W, 6, 10 } }) do
    for _, preset in ipairs({ { "slow", 2 }, { "normal", 1 }, { "fast", 0.5 } }) do
        store.swipe_animation_speed = preset[1]
        sleeps = {}
        refreshes = run("wipe", nil, nil, screen[1], screen[2])
        Assert.len(refreshes, screen[3])
        Assert.len(sleeps, screen[3] - 1)
        for _, delay in ipairs(sleeps) do
            Assert.eq(delay, screen[4] * preset[2] * 1000)
        end
    end
end

-- 未选速度时继续尊重旧版延迟；显式 0 不等待。
store.swipe_animation_speed = nil
sleeps = {}
run("wipe")
Assert.len(sleeps, 0)
store.swipe_animation_delay_ms_vertical = 37
sleeps = {}
run("wipe")
Assert.eq(sleeps[1], 37000)
store.swipe_animation_speed = "unknown"
sleeps = {}
run("wipe")
Assert.eq(sleeps[1], 37000, "非法速度不破坏旧延迟")

return true
