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
    2. the SwipeAnimation module: full-refresh / clearing decisions and the
       wipe animation itself (runSwipeAnimation), called from
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
    local logger = require("logger")
    -- Module-level cache to avoid repeated requires on the _repaint hot path
    local ReaderUI = require("apps/reader/readerui")
    -- Shared animation tuning (single source of truth, defined in uimanager.lua)
    local UIManager = require("ui/uimanager")
    -- For the frame delay sleep in the animation loop
    local ffi = require("ffi")

    local SwipeAnimation = {}

    ---------------------------------------------------------------
    -- 2.1 Whether this turn needs a clearing refresh after the animation
    ---------------------------------------------------------------
    function SwipeAnimation.shouldDoClearing(self)
        if not (self.FULL_REFRESH_COUNT and self.FULL_REFRESH_COUNT > 0) then
            return false
        end

        self._swipe_full_refresh_count = (self._swipe_full_refresh_count or 0) + 1

        if self._swipe_full_refresh_count >= self.FULL_REFRESH_COUNT then
            self._swipe_full_refresh_count = 0
            return true
        end
        return false
    end

    ---------------------------------------------------------------
    -- 2.2 Perform the clearing refresh (supports mild global refresh)
    ---------------------------------------------------------------
    ---@param screen_w number
    ---@param screen_h number
    function SwipeAnimation.performClearing(self, screen_w, screen_h)
        local mild = G_reader_settings:isTrue("swipe_animation_mild_global_refresh")

        if mild then
            Screen:refreshPartial(0, 0, screen_w, screen_h)
            logger.dbg("SwipeAnimation: mild (partial) clearing refresh")
        else
            Screen:refreshFull(0, 0, screen_w, screen_h)
            logger.dbg("SwipeAnimation: full clearing refresh")
        end

        self.refresh_count = 0
        self._refresh_stack = {}
    end

    ---------------------------------------------------------------
    -- 2.3 Whether a forced full refresh is needed (images / chapter boundaries)
    --     Can be called before the animation; accurate prev_page is required
    --     to correctly detect forward/backward chapter boundaries
    ---------------------------------------------------------------
    ---@param prev_page number|nil 翻页前的页码，缺省回退到 toc.pageno（精度更差）
    ---@return boolean
    function SwipeAnimation.shouldForceFullAfterAnimation(self, prev_page)
        local instance = ReaderUI.instance
        if not instance then
            return false
        end

        -- ===== Images(ReaderView:paintTo) =====
        local view = instance.view
        if view then
            local curr_coverage = view.img_coverage or 0
            local prev_coverage = view._swipe_prev_img_coverage or 0
            local coverage_diff = math.abs(curr_coverage - prev_coverage)

            view._swipe_prev_img_coverage = curr_coverage

            if curr_coverage >= 0.075 or coverage_diff >= 0.075 then
                if G_reader_settings:nilOrTrue("refresh_on_pages_with_images") then
                    return true
                end
            end
        end

        -- ===== Chapters (faithful recreation of ReaderToc:onPageUpdate) =====
        local toc = instance.toc
        if not toc then return false end

        if not (self.FULL_REFRESH_COUNT == -1 or G_reader_settings:isTrue("refresh_on_chapter_boundaries")) then
            return false
        end

        local paging = instance.paging
        local rolling = instance.rolling
        local current_page = (paging and paging.current_page) or (rolling and rolling.current_page)

        if not current_page then return false end

        -- If prev_page was not provided, fall back to toc.pageno
        -- (which may already be the new page, so less accurate)
        prev_page = prev_page or toc.pageno

        local flash_on_second = G_reader_settings:nilOrFalse("no_refresh_on_second_chapter_page")
        local paging_forward, paging_backward

        if flash_on_second and prev_page then
            if current_page > prev_page then
                paging_forward = true
            elseif current_page < prev_page then
                paging_backward = true
            end
        end

        if paging_backward and toc:isChapterEnd(current_page) then
            return true
        elseif toc:isChapterStart(current_page) then
            return true
        elseif paging_forward and toc:isChapterSecondPage(current_page) then
            return true
        end

        return false
    end

    ---------------------------------------------------------------
    -- 2.4 Actually trigger the full refresh
    --     Supports mild global refresh, consistent with performClearing
    ---------------------------------------------------------------
    ---@param screen_w number
    ---@param screen_h number
    function SwipeAnimation.forceFullAndReset(self, screen_w, screen_h)
        -- We are inside _repaint, so we must refresh directly;
        -- setDirty would be deferred to the next frame and become ineffective
        local mild = G_reader_settings:isTrue("swipe_animation_mild_global_refresh")

        if mild then
            Screen:refreshPartial(0, 0, screen_w, screen_h)
            logger.dbg("SwipeAnimation: mild (partial) forced refresh (image/chapter)")
        else
            Screen:refreshFull(0, 0, screen_w, screen_h)
            logger.dbg("SwipeAnimation: forced full refresh (image/chapter)")
        end

        self._swipe_full_refresh_count = 0
        self.refresh_count = 0
        self._refresh_stack = {}
    end

    ---------------------------------------------------------------
    -- 2.5 Run the software wipe animation
    --     Called from UIManager:_repaint (after the new page has been painted,
    --     before the queued refreshes are executed). Handles the clearing /
    --     forced-full decisions and the strip animation.
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

    -- A frame is a list of screen rects { x, y, w, h }; the player blits each
    -- rect from the new page and refreshes it. Every style is a *reveal*:
    -- each pixel is blitted and refreshed exactly once. On e-ink a pixel
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

    --- 随机线条：横条打乱顺序，每帧揭开若干条（方向无关）。
    ---@param edges number[]
    ---@param frames_max number
    ---@param span number
    ---@return table[] frames
    local function randomBars(edges, frames_max, span)
        local n = #edges - 1
        local order = {}
        for j = 1, n do order[j] = j end
        for j = n, 2, -1 do
            local r = math.random(j)
            order[j], order[r] = order[r], order[j]
        end
        local per = math.ceil(n / math.min(frames_max, n))
        local frames = {}
        for i, j in ipairs(order) do
            local k = math.ceil(i / per)
            frames[k] = frames[k] or {}
            frames[k][#frames[k] + 1] = slot(edges, j, true, span)
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
            for _, r in ipairs({
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
    -- frames and about 2 * steps refreshed rects per turn.
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
            return randomBars(buildStripEdges(h, steps * 2, align), steps, w)
        end,
        box = function(w, h, steps, align, forward)
            return box(w, h, math.ceil(steps / 2), align, forward)
        end,
    }

    --- 跑软件翻页动画：按所选风格把新页分块揭开，盖住旧页快照。
    --- 由 UIManager:_repaint 在新页画完、排队刷新执行前调用。
    --- 清屏页（每 N 页）/ 图片页 / 章节边界照常播动画，播完再补一次全屏刷新。
    --- 没有旧页快照时不播动画，只做需要的全屏刷新，其余排队刷新照常执行。
    function SwipeAnimation.runSwipeAnimation(self)
        local screen_w = Screen.bb:getWidth()
        local screen_h = Screen.bb:getHeight()

        -- Try to capture the previous page number before the animation decision
        -- Note: by the time we reach _repaint, paging/toc may already reflect the new page,
        -- so prev_page is not 100% reliable, but it is still better than not passing it
        -- and letting shouldForceFull fall back to toc.pageno.
        local prev_page = nil
        do
            local instance = ReaderUI.instance
            if instance then
                if instance.toc then
                    prev_page = instance.toc.pageno
                end
                if not prev_page then
                    prev_page = (instance.paging and instance.paging.current_page)
                             or (instance.rolling and instance.rolling.current_page)
                end
            end
        end

        -- Decide before animating: shouldForceFullAfterAnimation reads the
        -- page state and updates the image-coverage baseline.
        local do_clearing = SwipeAnimation.shouldDoClearing(self)
        local need_force_full = false
        if not do_clearing then
            need_force_full = SwipeAnimation.shouldForceFullAfterAnimation(self, prev_page)
        end

        local function finishRefresh()
            if need_force_full then
                SwipeAnimation.forceFullAndReset(self, screen_w, screen_h)
            elseif do_clearing then
                SwipeAnimation.performClearing(self, screen_w, screen_h)
            end
        end

        local saved_bb = Screen.saved_bb
        Screen.saved_bb = nil

        if not saved_bb then
            finishRefresh()
            return
        end

        -- ==================== Normal software swipe animation path ====================
        local new_bb = Screen.bb:copy()

        -- Support custom per-orientation animation frame delay set by the external plugin.
        -- Defaults come from UIManager.swipe_animation_defaults (single source of truth).
        local is_landscape = screen_w > screen_h
        local delay_defaults = (UIManager.swipe_animation_defaults or {}).delay_ms or {}
        local anim_refresh_mode = G_reader_settings:readSetting("swipe_animation_refresh_mode") or "ui"
        local delay_ms
        if is_landscape then
            delay_ms = tonumber(G_reader_settings:readSetting("swipe_animation_delay_ms_horizontal"))
        else
            delay_ms = tonumber(G_reader_settings:readSetting("swipe_animation_delay_ms_vertical"))
        end
        if delay_ms == nil then
            delay_ms = tonumber(G_reader_settings:readSetting("swipe_animation_delay_ms"))
        end
        -- Unset: 10/20ms for both UI and Fast. Explicit 0 means no usleep.
        if delay_ms == nil or delay_ms < 0 then
            delay_ms = is_landscape
                and (delay_defaults.landscape or 10)
                or  (delay_defaults.portrait or 20)
        end

        -- Hoisted for slight efficiency in the animation loop
        local usleep = ffi and ffi.C and ffi.C.usleep

        -- Use fewer animation steps in landscape mode for better visual feel
        local step_defaults = (UIManager.swipe_animation_defaults or {}).steps or {}
        local steps = is_landscape
            and (step_defaults.landscape or 6)
            or  (step_defaults.portrait or 8)
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
            for _, r in ipairs(frame) do
                Screen.bb:blitFrom(new_bb, r[1], r[2], r[1], r[2], r[3], r[4])
                refresh_fn(Screen, r[1], r[2], r[3], r[4])
            end
            if i < #frames and usleep and delay_ms > 0 then
                usleep(delay_ms * 1000)
            end
        end

        self._refresh_stack = {}
        new_bb:free()
        saved_bb:free()
        finishRefresh()
    end

    _G.SwipeAnimation = SwipeAnimation
end)

if not ok then
    require("logger").warn("[SwipeAnimationCorePatch] failed:", err)
end
