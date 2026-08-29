--[[--
主页：可组合组件（默认最近阅读列表铺满）。

@module koplugin.book.ui.home
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local TextWidget = require("ui/widget/textwidget")
local BookInfo = require("ui.components.bookinfo")
local UI = require("ui.components.bookui")
local MoonSettings = require("utils.settings")
local Enrich = require("ui.desktop.home.enrich")
local HomeStats = require("ui.desktop.home.stats")
local Layout = require("ui.desktop.home.layout")
local Highlights = require("book.highlights")
local logger = require("logger")
local gettext = require("gettext")
local Screen = Device.screen

local Home = {}

--- 书摘：按当前索引取一条，不递增。
---@param recent table|nil
---@return table|nil
local function pickExcerpt(recent)
    if not recent or not recent.source_id or not recent.stable_id then
        return nil
    end
    local chapter_idx = recent.chapter_idx or recent.last_chapter_idx
    local home = MoonSettings.get("home")
    local index = tonumber(home.home_excerpt_index) or 0
    local text, source = Highlights.pick(
        recent.source_id, recent.stable_id, chapter_idx, index + 1
    )
    if not text then return nil end
    return { text = text, source = source }
end

--- 书摘轮换：递增索引后取一条（仅离开阅读回到桌面时调用）。
---@param recent table|nil
---@return table|nil
local function rotateExcerpt(recent)
    if not recent or not recent.source_id or not recent.stable_id then
        return nil
    end
    local chapter_idx = recent.chapter_idx or recent.last_chapter_idx
    local items = Highlights.collect(recent.source_id, recent.stable_id, chapter_idx)
    if #items == 0 then return nil end
    local home = MoonSettings.get("home")
    local index = (tonumber(home.home_excerpt_index) or 0) + 1
    home.home_excerpt_index = index
    MoonSettings.saveSection("home", home)
    local text, source = Highlights.pick(
        recent.source_id, recent.stable_id, chapter_idx, index
    )
    if not text then return nil end
    return { text = text, source = source }
end

--- 一言 / 书摘只读缓存与本地高亮，不做定时或重复网络刷新。
---@param state table
---@param rotate_excerpt boolean|nil
local function fillExtras(state, rotate_excerpt)
    local c = MoonSettings.get()
    state.quote = {
        text = c.lock_screen_quote_cache,
        source = c.lock_screen_quote_source_cache,
    }
    if state.recent then
        local excerpt = rotate_excerpt and rotateExcerpt(state.recent) or pickExcerpt(state.recent)
        if excerpt then
            state.excerpt = excerpt
        end
    end
    return state
end

--- 首页数据作废：取消在飞取数、清全部首页状态；当前在首页则立即重建（重建会重新 fetch）。
--- 这是唯一允许清首页状态的地方，禁止在别处手写 _home_state / _home_loaded。
---@param desktop table
function Home.invalidate(desktop)
    if not desktop or desktop._closed then return end
    -- 先废弃回调资格，再取消句柄。cancel 只是尽力而为，旧回调仍可能晚到。
    desktop._home_fetch_request = nil
    local job = desktop._home_fetch_cancel
    if type(job) == "table" and type(job.cancel) == "function" then
        pcall(job.cancel)
    end
    desktop._home_fetch_cancel = nil
    desktop._home_fetching = false
    desktop._home_state = nil
    desktop._home_loaded = false
    desktop._home_reading_page = 1
    if desktop.tab == "home" then
        desktop:rebuild()
    end
end

--- 进入首页的唯一入口：Tab 切入 / 唤醒 / 从阅读回桌面都走这里，语义固定为「刷新一遍」。
---@param desktop table
function Home.enter(desktop)
    if not desktop or desktop._closed then return end
    Home.invalidate(desktop)
    desktop:scheduleClockTick()
    if desktop.plugin and desktop.plugin.emitToSource then
        desktop.plugin:emitToSource("home_open", desktop)
    end
end

--- 离开阅读回到桌面：标记书摘轮换，然后按统一入口刷新（fetch 完成时轮换）。
---@param desktop table
function Home.onReturnToDesktop(desktop)
    if not desktop or desktop._closed then return end
    desktop._home_rotate_excerpt = true
    Home.invalidate(desktop)
end

--- 异步拉取最近阅读与本地统计。
---@param desktop table
function Home.fetch(desktop)
    if desktop._home_fetching then return end
    desktop._home_fetching = true

    if desktop._home_fetch_cancel then
        desktop._home_fetch_cancel:cancel()
        desktop._home_fetch_cancel = nil
    end

    local source = desktop.source
    local generation = desktop.source_generation or 0
    local request = {}
    desktop._home_fetch_request = request
    --- 本次拉取结果是否还该采用。
    --- 桌面已关或期间换过源（source_generation 变化）时回调必须丢弃，否则会串源写状态。
    ---@return boolean
    local function valid()
        return not desktop._closed
            and desktop.source == source
            and (desktop.source_generation or 0) == generation
            and desktop._home_fetch_request == request
    end

    if not desktop._local_cleanup_done then
        desktop._local_cleanup_done = true
        desktop._local_cleanup_job = require("book.cache").cleanupStaleAsync(function(ok, n)
            desktop._local_cleanup_job = nil
            if ok and n and n > 0 then
                logger.info("book cleaned stale local books:", n)
            elseif not ok then
                logger.warn("book local cleanup failed")
            end
        end)
    end

    --- 写入主页状态并重建。
    ---@param state table|nil
    local function finish(state)
        if not valid() then return end
        desktop._home_fetching = false
        desktop._home_fetch_cancel = nil
        local rotate = desktop._home_rotate_excerpt
        desktop._home_rotate_excerpt = nil
        state = fillExtras(state or {}, rotate)
        desktop._home_state = state
        desktop._home_loaded = true
        local visible = desktop.tab == "home"
        -- 成功回调也只能消费一次；后到的重复回调视为失效。
        desktop._home_fetch_request = nil
        if visible then desktop:rebuild() end
    end

    if not source then finish({ recent_err = gettext("当前数据源不可用"), reading = {} }); return end
    local job = source:recentBooksAsync(24, function(res, err)
        if not valid() then
            -- 取消只是尽力而为；旧回调不能碰新一轮请求的任何状态。
            return
        end
        local applied, boom = pcall(function()
            if not res then
                finish({
                    recent = nil,
                    recent_err = err or gettext("加载失败"),
                    reading = {},
                })
                return
            end
            local rows = res.data or {}
            local recent = rows[1]
            local skip = recent and BookInfo.file(recent)
            local reading = {}
            for i, book in ipairs(rows) do
                if BookInfo.file(book) ~= skip then
                    table.insert(reading, book)
                end
            end
            recent, reading = Enrich.apply(recent, reading)
            finish({
                recent = recent,
                reading = reading,
                stats = HomeStats.summarize(source.id),
            })
        end)
        if not applied then
            logger.err("book home fetch apply failed:", boom)
            finish({ recent_err = tostring(boom), reading = {} })
        end
    end)
    -- 有些本地源同步回调；完成后不能把已结束任务句柄重新挂回桌面。
    if desktop._home_fetch_request == request then
        desktop._home_fetch_cancel = job
    end
end

--- Desktop rebuild 入口：未加载则触发 fetch。
---@param desktop table
---@return table
function Home.page(desktop)
    local h = desktop:contentHeight()
    local w = (desktop.dimen and desktop.dimen.w) or Screen:getWidth()
    if not desktop._home_loaded then
        UIManager:nextTick(function()
            if desktop._closed or desktop.tab ~= "home" then return end
            Home.fetch(desktop)
        end)
        return FrameContainer:new{
            bordersize = 0,
            padding = 0,
            background = Blitbuffer.COLOR_WHITE,
            dimen = Geom:new{ w = w, h = h },
            CenterContainer:new{
                dimen = Geom:new{ w = w, h = h },
                TextWidget:new{
                    text = gettext("加载主页…"),
                    face = UI.face("cfont", 18),
                    fgcolor = UI.muted(),
                },
            },
        }
    end
    return Layout.build(desktop:ctx(), desktop._home_state or {})
end

return Home
