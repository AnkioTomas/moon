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
local Base = require("ui.desktop.home.components.base")
local logger = require("logger")
local gettext = require("gettext")
local Screen = Device.screen

local Home = {}

local Hitokoto = require("lockscreen.components.hitokoto")

--- 书摘轮换：递增索引并取一条高亮。
---@param recent table|nil
---@return table|nil excerpt { text, source }
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

--- 从缓存填充一言到 state（首屏不阻塞）。
---@param state table
local function fillQuoteCache(state)
    local c = MoonSettings.get()
    state.quote = {
        text = c.lock_screen_quote_cache,
        source = c.lock_screen_quote_source_cache,
    }
end

--- 合并书摘 / 一言缓存；rotate 为 true 时轮换书摘。
---@param desktop table
---@param rotate boolean|nil
local function applyExtras(desktop, rotate)
    local state = desktop._home_state or {}
    if rotate then
        local excerpt = rotateExcerpt(state.recent)
        if excerpt then
            state.excerpt = excerpt
        end
    end
    fillQuoteCache(state)
    desktop._home_state = state
end

--- 后台拉一言；仅文案变化时再 rebuild。
---@param desktop table
local function refreshQuote(desktop)
    if desktop._home_quote_job then
        desktop._home_quote_job:cancel()
        desktop._home_quote_job = nil
    end
    desktop._home_quote_job = Hitokoto.ensureText(function(text, source)
        desktop._home_quote_job = nil
        if desktop._closed or desktop.tab ~= "home" then return end
        local cur = desktop._home_state or {}
        local old = cur.quote
        if old and old.text == text and old.source == source then
            return
        end
        cur.quote = { text = text, source = source }
        desktop._home_state = cur
        desktop:rebuild()
    end)
end

--- 回到桌面：轮换书摘 + 后台更新一言（单次 rebuild）。
---@param desktop table
function Home.onShow(desktop)
    if not desktop or desktop._closed or desktop.tab ~= "home" then return end
    if not desktop._home_loaded then return end
    applyExtras(desktop, true)
    desktop:rebuild()
    refreshQuote(desktop)
end

--- 构建主页。
---@param ctx table
---@param state table
---@return table
function Home.build(ctx, state)
    return Layout.build(ctx, state)
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
    local function valid()
        return not desktop._closed
            and desktop.source == source
            and (desktop.source_generation or 0) == generation
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
        desktop._home_fetching = false
        desktop._home_fetch_cancel = nil
        desktop._home_state = state or {}
        desktop._home_loaded = true
        if not valid() or desktop.tab ~= "home" then
            return
        end
        applyExtras(desktop, true)
        desktop:rebuild()
        refreshQuote(desktop)
    end

    if not source then finish({ recent_err = gettext("当前数据源不可用"), reading = {} }); return end
    desktop._home_fetch_cancel = source:recentBooksAsync(24, function(res, err)
        if not valid() then
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
end

--- Desktop rebuild 入口：未加载则触发 fetch。
---@param desktop table
---@return table
function Home.page(desktop)
    local h = desktop:contentHeight()
    local w = (desktop.dimen and desktop.dimen.w) or Screen:getWidth()
    if not desktop._home_loaded then
        desktop._home_loaded = true
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
    return Home.build(desktop:ctx(), desktop._home_state or {})
end

--- 首页是否启用时钟组件（顶栏分钟 tick 联动）。
---@return boolean
function Home.hasClock()
    return Base.hasComponent("clock")
end

return Home
