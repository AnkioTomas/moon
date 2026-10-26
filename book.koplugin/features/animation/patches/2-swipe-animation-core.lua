--[[
    2-swipe-animation-core.lua

    Adapted from Swipe_Animation.koplugin (GPLv3) for the Book plugin's
    patch manager. The animation core is ported verbatim; the settings-menu
    injection is removed in favor of the plugin's own toggle.

    Runtime core of the Swipe_Animation patch (merged from the former
    2-mtk-swipe-direction.lua, 2-swipe-animation-framebuffer.lua and
    2-swipe-full-refresh-judgment.lua):

    1. framebuffer integration: wrap Screen methods so ffi/framebuffer.lua
       stays 100% upstream (snapshot the pre-paint screen, persist the swipe
       state). The setSwipeDirection wrapper also covers MTK: on MTK devices
       the original method is the rotation-aware hardware ioctl setup, which
       we preserve, and we additionally store swipe_forward for the software
       animation.
    2. the SwipeAnimation module: the wipe animation itself
       (runSwipeAnimation), honoring KOReader's queued full refresh, called from
       UIManager:_repaint after the new page is painted.
    3. Kobo MTK fence immediately before the wipe loop: drain a leftover
       PARTIAL, or pay one AUTO+wait after a FULL, so the first strips are
       not blocked by HWTCON serialization.

    Prefer original data sources, but trigger Screen:refreshFull / refreshPartial
    directly (because we are inside _repaint, where setDirty would be deferred
    and ineffective).
]]

local ok, err = pcall(function()
    local Device = require("device")
    local Screen = Device.screen
    if not Screen then
        return
    end

    -- ==================== 1. framebuffer integration ====================
    if not Screen._swipe_animation_core_patch_applied then
        Screen._swipe_animation_core_patch_applied = true

        -- Snapshot the current framebuffer before the new page is painted,
        -- but only once per repaint (beforePaint can be called once per dirty
        -- widget in the same repaint cycle). This is the "previous page" used
        -- by the wipe effect.
        local orig_beforePaint = Screen.beforePaint
        --- 绘制新页之前快照当前帧缓冲，作为翻页动画的「旧页」。
        --- 一轮重绘里每个脏 widget 都会调到，用 painting 标记保证只快照一次。
        function Screen:beforePaint()
            if not self.painting then
                self.painting = true
                if self.swipe_animations then
                    if self.saved_bb then self.saved_bb:free() end
                    self.saved_bb = self.bb:copy()
                end
            end
            if orig_beforePaint then
                return orig_beforePaint(self)
            end
        end

        local orig_afterPaint = Screen.afterPaint
        --- 本轮重绘结束：解掉 painting 标记，下一轮才会重新快照。
        function Screen:afterPaint()
            self.painting = false
            if orig_afterPaint then
                return orig_afterPaint(self)
            end
        end

        -- The upstream base framebuffer only declares these as stubs; persist
        -- the state so the software animation can read it.
        local orig_setSwipeAnimations = Screen.setSwipeAnimations
        --- 记下翻页动画开关：上游基类只有空实现，软件动画要靠这个状态判断。
        ---@param enabled boolean
        function Screen:setSwipeAnimations(enabled)
            if orig_setSwipeAnimations then
                orig_setSwipeAnimations(self, enabled)
            end
            self.swipe_animations = enabled
        end

        -- On MTK devices the original setSwipeDirection is the rotation-aware
        -- hardware ioctl setup (framebuffer_mxcfb); calling it preserves the
        -- native behavior, and storing swipe_forward keeps the software
        -- animation direction in sync. This replaces the former
        -- 2-mtk-swipe-direction.lua.
        local orig_setSwipeDirection = Screen.setSwipeDirection
        --- 记下翻页方向；MTK 设备上原方法是硬件 ioctl 配置，必须先调原方法再存状态。
        ---@param direction boolean 是否向前翻
        function Screen:setSwipeDirection(direction)
            if orig_setSwipeDirection then
                orig_setSwipeDirection(self, direction)
            end
            self.swipe_forward = direction
        end
    end

    -- ==================== 2. SwipeAnimation module ====================
    -- For the frame delay sleep in the animation loop
    local ffi = require("ffi")
    -- Gray levels for the page-turn shadow
    local Blitbuffer = require("ffi/blitbuffer")

    local SwipeAnimation = {}

    -- Frame delay (ms) and frame budget per orientation; fewer, faster
    -- frames in landscape feel better.
    local DELAY_MS = { landscape = 10, portrait = 20 }
    local SPEED_FACTORS = { slow = 2, normal = 1, fast = 0.5 }
    local STEPS = { landscape = 6, portrait = 8 }

    ---------------------------------------------------------------
    -- 2.1 Full refresh after the animation
    --     KOReader has already queued a "full" refresh for this repaint when
    --     one is due (refresh-count promotion, chapter boundary, image page).
    --     The animation drops the queue, so read KOReader's decision first
    --     instead of re-deriving it.
    ---------------------------------------------------------------
    ---@param stack table[] UIManager._refresh_stack
    ---@return boolean
    local function wantsFull(stack)
        for _idx, refresh in ipairs(stack) do
            if refresh.mode == "full" then return true end
        end
        return false
    end

    --- 动画后补一次整屏刷新；开了柔和全刷则用 partial（不闪屏）。
    --- 身处 _repaint 内，setDirty 要等下一轮，只能直接刷。
    ---@param screen_w number
    ---@param screen_h number
    local function refreshAll(screen_w, screen_h)
        if G_reader_settings:isTrue("swipe_animation_mild_global_refresh") then
            Screen:refreshPartial(0, 0, screen_w, screen_h)
        else
            Screen:refreshFull(0, 0, screen_w, screen_h)
        end
    end

    ---------------------------------------------------------------
    -- 2.2 Run the software wipe animation
    --     Called from UIManager:_repaint (after the new page has been painted,
    --     before the queued refreshes are executed).
    ---------------------------------------------------------------
    -- Interior cuts snap to `align` (Screen.alignment_constraint, 16 on
    -- Kobo MTK) so getBoundedRect does not expand neighbouring strips
    -- into each other. Last edge stays the real size.
    ---@param size number 屏幕宽或高（最后一条边界保持真实尺寸）
    ---@param steps number 期望的条带数
    ---@param align number|nil 对齐粒度（Screen.alignment_constraint），小于 2 视为不对齐
    ---@return number[] 递增的切分边界，含 0 与 size
    local function buildStripEdges(size, steps, align)
        local edges = {0}
        local use_align = type(align) == "number" and align >= 2
        for i = 1, steps - 1 do
            local raw = size * i / steps
            local cut
            if use_align then
                cut = math.floor((raw + align / 2) / align) * align
            else
                cut = math.floor(raw)
            end
            if cut > edges[#edges] and cut < size then
                edges[#edges + 1] = cut
            end
        end
        edges[#edges + 1] = size
        return edges
    end

    -- A frame is a list of screen rects { x, y, w, h [, fill] }; the player
    -- blits each rect from the new page (or, with `fill`, paints the listed
    -- gray levels as equal vertical bands) and refreshes it. Every style is a
    -- *reveal*: each pixel is revealed and refreshed exactly once; the only
    -- exception is the narrow shadow fill, which the next frame reveals over.
    -- On e-ink a pixel
    -- refreshed again costs another waveform pass and leaves ghosting, so
    -- moving-content transitions (push / cover / page curl) and per-frame
    -- full-screen effects (fade / dissolve) are deliberately absent.
    local BLINDS = 4

    --- 第 j 条带的矩形。across_y=false 为竖条（沿 x 切），true 为横条（沿 y 切）。
    ---@param edges number[]
    ---@param j number
    ---@param across_y boolean
    ---@param span number 条带另一维的长度（整屏宽或高）
    ---@return number[] rect
    local function slot(edges, j, across_y, span)
        local a, len = edges[j], edges[j + 1] - edges[j]
        if across_y then return { 0, a, span, len } end
        return { a, 0, len, span }
    end

    --- 条带交错揭开：第 k 帧揭开每组第 k 条；只有一组时就是普通擦除。
    ---@param edges number[]
    ---@param frames_max number
    ---@param from_end boolean 每组从末端（右 / 下）开始揭
    ---@param across_y boolean
    ---@param span number
    ---@return table[] frames
    local function interleave(edges, frames_max, from_end, across_y, span)
        local n = #edges - 1
        local m = math.min(frames_max, n)
        local frames = {}
        for k = 1, m do frames[k] = {} end
        for j = 1, n do
            local k = (j - 1) % m + 1
            if from_end then k = m - k + 1 end
            local f = frames[k]
            f[#f + 1] = slot(edges, j, across_y, span)
        end
        return frames
    end

    ---@param frames table[]
    ---@return table[] frames 原地倒序
    local function reversed(frames)
        for i = 1, math.floor(#frames / 2) do
            local j = #frames - i + 1
            frames[i], frames[j] = frames[j], frames[i]
        end
        return frames
    end

    --- 分割：向前翻从中间往两边揭，向后翻从两边往中间揭。
    ---@param edges number[]
    ---@param forward boolean
    ---@param span number
    ---@return table[] frames
    local function split(edges, forward, span)
        local n = #edges - 1
        local frames = {}
        for lo = math.ceil(n / 2), 1, -1 do
            local hi = n - lo + 1
            local f = { slot(edges, lo, false, span) }
            if hi ~= lo then f[2] = slot(edges, hi, false, span) end
            frames[#frames + 1] = f
        end
        return forward and frames or reversed(frames)
    end

    ---@param list table
    ---@return table list 原地打乱
    local function shuffle(list)
        for i = #list, 2, -1 do
            local j = math.random(i)
            list[i], list[j] = list[j], list[i]
        end
        return list
    end

    --- 按顺序把矩形平均分进不超过 frames_max 帧。
    ---@param rects table[]
    ---@param frames_max number
    ---@return table[] frames
    local function chunk(rects, frames_max)
        local per = math.ceil(#rects / math.min(frames_max, #rects))
        local frames = {}
        for i, r in ipairs(rects) do
            local k = math.ceil(i / per)
            frames[k] = frames[k] or {}
            frames[k][#frames[k] + 1] = r
        end
        return frames
    end

    --- 网格格子，cells[row][col]，从左上开始。
    ---@param w number
    ---@param h number
    ---@param cols number
    ---@param rows number
    ---@param align number|nil
    ---@return table[][] cells
    local function grid(w, h, cols, rows, align)
        local xs, ys = buildStripEdges(w, cols, align), buildStripEdges(h, rows, align)
        local cells = {}
        for r = 1, #ys - 1 do
            cells[r] = {}
            for c = 1, #xs - 1 do
                cells[r][c] = { xs[c], ys[r], xs[c + 1] - xs[c], ys[r + 1] - ys[r] }
            end
        end
        return cells
    end

    --- 行优先展开（阅读顺序）。
    ---@param cells table[][]
    ---@return table[] rects
    local function flatten(cells)
        local out = {}
        for _idx, row in ipairs(cells) do
            for _idx, cell in ipairs(row) do out[#out + 1] = cell end
        end
        return out
    end

    --- 顺时针螺旋顺序，由外圈到内圈，从左上角出发。
    ---@param cells table[][]
    ---@return table[] rects
    local function spiral(cells)
        local top, bottom, left, right = 1, #cells, 1, #cells[1]
        local out = {}
        while top <= bottom and left <= right do
            for c = left, right do out[#out + 1] = cells[top][c] end
            for r = top + 1, bottom do out[#out + 1] = cells[r][right] end
            if top < bottom then
                for c = right - 1, left, -1 do out[#out + 1] = cells[bottom][c] end
            end
            if left < right then
                for r = bottom - 1, top + 1, -1 do out[#out + 1] = cells[r][left] end
            end
            top, bottom, left, right = top + 1, bottom - 1, left + 1, right - 1
        end
        return out
    end

    -- Shadow gradient painted on the old page next to the moving edge,
    -- listed left to right; the darkest band touches the edge.
    local SHADOW_W = 16
    local SHADOW = {
        Blitbuffer.COLOR_LIGHT_GRAY, Blitbuffer.COLOR_GRAY_9,
        Blitbuffer.COLOR_GRAY_7, Blitbuffer.COLOR_GRAY_4,
    }
    local SHADOW_REV = { SHADOW[4], SHADOW[3], SHADOW[2], SHADOW[1] }

    --- 翻页阴影：擦除前沿在旧页一侧涂一条渐变阴影，下一帧揭开时被新页盖掉。
    --- 阴影条是唯一会被刷两次的区域（窄带，代价可控）；最后一帧没有阴影。
    ---@param edges number[]
    ---@param forward boolean
    ---@param span number
    ---@return table[] frames
    local function shadow(edges, forward, span)
        local n = #edges - 1
        local frames = {}
        for i = 1, n do
            local j = forward and (n - i + 1) or i
            local f = { slot(edges, j, false, span) }
            if forward and j > 1 then
                local x = math.max(edges[j - 1], edges[j] - SHADOW_W)
                f[2] = { x, 0, edges[j] - x, span, SHADOW }
            elseif not forward and j < n then
                local x1 = math.min(edges[j + 2], edges[j + 1] + SHADOW_W)
                f[2] = { edges[j + 1], 0, x1 - edges[j + 1], span, SHADOW_REV }
            end
            frames[i] = f
        end
        return frames
    end

    --- 以中心为基准、逐级放大的区间；第 0 级退化为中心一点，第 m 级为整段。
    ---@param size number
    ---@param m number
    ---@param align number|nil
    ---@return table[] levels levels[k + 1] = { lo, hi }
    local function levels(size, m, align)
        local a = (type(align) == "number" and align >= 2) and align or 1
        local mid = size / 2
        local c = math.floor(mid / a) * a
        local out = { { c, c } }
        for k = 1, m do
            local half = mid * k / m
            out[k + 1] = {
                math.floor((mid - half) / a) * a,
                math.min(size, math.ceil((mid + half) / a) * a),
            }
        end
        out[m + 1] = { 0, size }
        return out
    end

    --- 方框：矩形从中心向外逐圈揭开（向前翻），向后翻由外向内收拢。
    --- 每圈拆成上下左右四块，零面积的块直接丢弃。
    ---@param screen_w number
    ---@param screen_h number
    ---@param m number 圈数
    ---@param align number|nil
    ---@param forward boolean
    ---@return table[] frames
    local function box(screen_w, screen_h, m, align, forward)
        local xs, ys = levels(screen_w, m, align), levels(screen_h, m, align)
        local frames = {}
        for k = 1, m do
            local x0, x1 = xs[k + 1][1], xs[k + 1][2]
            local y0, y1 = ys[k + 1][1], ys[k + 1][2]
            local ix0, ix1 = xs[k][1], xs[k][2]
            local iy0, iy1 = ys[k][1], ys[k][2]
            local f = {}
            for _idx, r in ipairs({
                { x0, y0, x1 - x0, iy0 - y0 },
                { x0, iy1, x1 - x0, y1 - iy1 },
                { x0, iy0, ix0 - x0, iy1 - iy0 },
                { ix1, iy0, x1 - ix1, iy1 - iy0 },
            }) do
                if r[3] > 0 and r[4] > 0 then f[#f + 1] = r end
            end
            if f[1] then frames[#frames + 1] = f end
        end
        return forward and frames or reversed(frames)
    end

    -- Keys are the values of G_reader_settings "swipe_animation_style";
    -- unknown / unset values fall back to wipe. Budget: at most `steps`
    -- frames and about 2 * steps refreshed rects per turn, hence grid styles
    -- use a ceil(steps / 2) square grid (4x4 portrait, 3x3 landscape).
    local function gridSize(steps) return math.ceil(steps / 2) end

    SwipeAnimation.STYLES = {
        wipe = function(w, h, steps, align, forward)
            return interleave(buildStripEdges(w, steps, align), steps, forward, false, h)
        end,
        wipe_vertical = function(w, h, steps, align, forward)
            return interleave(buildStripEdges(h, steps, align), steps, not forward, true, w)
        end,
        split = function(w, h, steps, align, forward)
            return split(buildStripEdges(w, steps, align), forward, h)
        end,
        blinds = function(w, h, steps, align, forward)
            local m = math.ceil(steps / 2)
            return interleave(buildStripEdges(w, m * BLINDS, align), m, forward, false, h)
        end,
        random_bars = function(w, h, steps, align)
            local edges, bars = buildStripEdges(h, steps * 2, align), {}
            for j = 1, #edges - 1 do bars[j] = slot(edges, j, true, w) end
            return chunk(shuffle(bars), steps)
        end,
        box = function(w, h, steps, align, forward)
            return box(w, h, gridSize(steps), align, forward)
        end,
        shadow = function(w, h, steps, align, forward)
            return shadow(buildStripEdges(w, steps, align), forward, h)
        end,
        -- 逐行：按阅读顺序（行内从左到右）揭开；向后翻倒放。
        typewriter = function(w, h, steps, align, forward)
            local g = gridSize(steps)
            local frames = chunk(flatten(grid(w, h, g, g, align)), steps)
            return forward and frames or reversed(frames)
        end,
        -- 螺旋：向前翻由外圈旋入，向后翻由中心旋出。
        spiral = function(w, h, steps, align, forward)
            local g = gridSize(steps)
            local frames = chunk(spiral(grid(w, h, g, g, align)), steps)
            return forward and frames or reversed(frames)
        end,
        -- 时钟：四象限从 12 点起顺时针（向后翻逆时针）。
        clock = function(w, h, _steps, align, forward)
            local q = grid(w, h, 2, 2, align)
            local tl, tr, br, bl = q[1][1], q[1][2], q[2][2], q[2][1]
            if forward then return { { tr }, { br }, { bl }, { tl } } end
            return { { tl }, { bl }, { br }, { tr } }
        end,
        -- 棋盘：两拍，先揭一色格再揭另一色；向后翻两拍互换。
        checkerboard = function(w, h, steps, align, forward)
            local g = gridSize(steps)
            local a, b = {}, {}
            for r, row in ipairs(grid(w, h, g, g, align)) do
                for c, cell in ipairs(row) do
                    local t = (r + c) % 2 == 0 and a or b
                    t[#t + 1] = cell
                end
            end
            if forward then return { a, b } end
            return { b, a }
        end,
        -- 梳状：横带交替从两侧擦入，向前翻奇数带从右侧开始。
        comb = function(w, h, steps, align, forward)
            local g = gridSize(steps)
            local cells = grid(w, h, g, g, align)
            local frames = {}
            for k = 1, #cells[1] do
                local f = {}
                for b, row in ipairs(cells) do
                    local from_right = (b % 2 == 1) == forward
                    f[#f + 1] = row[from_right and (#row - k + 1) or k]
                end
                frames[k] = f
            end
            return frames
        end,
        -- 斜向擦除：沿对角线推进，向前翻从右上角开始，向后翻从左上角开始。
        diagonal = function(w, h, steps, align, forward)
            local g = gridSize(steps)
            local frames = {}
            for r, row in ipairs(grid(w, h, g, g, align)) do
                for c, cell in ipairs(row) do
                    local k = forward and (#row - c + r) or (c + r - 1)
                    frames[k] = frames[k] or {}
                    frames[k][#frames[k] + 1] = cell
                end
            end
            return frames
        end,
        random_blocks = function(w, h, steps, align)
            local g = gridSize(steps)
            return chunk(shuffle(flatten(grid(w, h, g, g, align))), steps)
        end,
    }

    --- 把 fill 灰阶按等宽竖带涂满矩形（最后一带吃掉余数）。
    ---@param r table { x, y, w, h, fill }
    local function paintFill(r)
        local fill = r[5]
        local band = math.floor(r[3] / #fill)
        for b, color in ipairs(fill) do
            local bx = r[1] + (b - 1) * band
            local bw = b < #fill and band or r[1] + r[3] - bx
            Screen.bb:paintRect(bx, r[2], bw, r[4], color)
        end
    end

    --- 跑软件翻页动画：按所选风格把新页分块揭开，盖住旧页快照。
    --- 由 UIManager:_repaint 在新页画完、排队刷新执行前调用。
    --- KOReader 本轮排了全刷（每 N 页 / 图片页 / 章节边界）时照常播动画，播完再补一次整屏刷新。
    --- 没有旧页快照时不播动画，排队刷新（含全刷）原样交回 KOReader 执行。
    function SwipeAnimation.runSwipeAnimation(self)
        local saved_bb = Screen.saved_bb
        Screen.saved_bb = nil
        if not saved_bb then return end

        local screen_w = Screen.bb:getWidth()
        local screen_h = Screen.bb:getHeight()
        local need_full = wantsFull(self._refresh_stack)
        local new_bb = Screen.bb:copy()

        -- Per-orientation frame delay; settings may be inherited from the
        -- external Swipe_Animation plugin. Explicit 0 means no usleep.
        local orientation = screen_w > screen_h and "landscape" or "portrait"
        local delay_ms = tonumber(G_reader_settings:readSetting(orientation == "landscape"
            and "swipe_animation_delay_ms_horizontal" or "swipe_animation_delay_ms_vertical"))
            or tonumber(G_reader_settings:readSetting("swipe_animation_delay_ms"))
        if delay_ms == nil or delay_ms < 0 then
            delay_ms = DELAY_MS[orientation]
        end
        local speed = SPEED_FACTORS[G_reader_settings:readSetting("swipe_animation_speed")]
        if speed then delay_ms = DELAY_MS[orientation] * speed end
        local usleep = ffi.C.usleep
        local steps = STEPS[orientation]
        local anim_refresh_mode = G_reader_settings:readSetting("swipe_animation_refresh_mode") or "ui"
        local swipe_forward = Screen.swipe_forward
        if swipe_forward == nil then
            -- Some framebuffer implementations never call setSwipeDirection();
            -- default to the forward direction instead of always sweeping one way.
            swipe_forward = true
        end
        local style = SwipeAnimation.STYLES[G_reader_settings:readSetting("swipe_animation_style")]
            or SwipeAnimation.STYLES.wipe
        local frames = style(screen_w, screen_h, steps, Screen.alignment_constraint, swipe_forward)
        local refresh_fn = anim_refresh_mode == "fast" and Screen.refreshFast or Screen.refreshUI

        -- Draw the previous page as the starting background
        Screen.bb:blitFrom(saved_bb, 0, 0, 0, 0, screen_w, screen_h)

        -- Kobo MTK: leftover PARTIAL AUTO still serializes the first strip;
        -- after a FULL, waitForLast is a no-op (dont_wait_for_marker == marker)
        -- so pay one AUTO+wait here. Consecutive turns skip the extra refresh.
        if Device:isKobo() and Device:isMTK() then
            if Screen.refreshWaitForLast then
                Screen:refreshWaitForLast()
            end
            if Screen.dont_wait_for_marker == Screen.marker then
                Screen:refreshUI(0, 0, screen_w, screen_h)
                if Screen.refreshWaitForLast then
                    Screen:refreshWaitForLast()
                end
            end
        end

        for i, frame in ipairs(frames) do
            for _idx, r in ipairs(frame) do
                if r[5] then
                    paintFill(r)
                else
                    Screen.bb:blitFrom(new_bb, r[1], r[2], r[1], r[2], r[3], r[4])
                end
                refresh_fn(Screen, r[1], r[2], r[3], r[4])
            end
            if i < #frames and delay_ms > 0 then
                usleep(delay_ms * 1000)
            end
        end

        self._refresh_stack = {}
        new_bb:free()
        saved_bb:free()
        if need_full then refreshAll(screen_w, screen_h) end
    end

    _G.SwipeAnimation = SwipeAnimation
end)

if not ok then
    require("logger").warn("[SwipeAnimationCorePatch] failed:", err)
end
