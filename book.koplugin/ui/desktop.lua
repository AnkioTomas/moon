--[[--
月读桌面壳 — 顶栏 + 底栏 + Tab 内容拼装。
  页逻辑在 home / library / store / insight / settings；本文件只做窗体与手势。

布局（OverlapGroup 叠层）：
  +-----------------------------------------------+
  | TopBar（时钟 · 源名 · 剩余内存/存储/Wi‑Fi/亮度/电量） |
  |-----------------------------------------------|
  |                                               |
  |          Tab 内容区（contentHeight）           |
  |                                               |
  |-----------------------------------------------|
  | BottomBar  首页|图书馆|[书城]|[统计]|设置      |
  +-----------------------------------------------+
  手势：底栏 tap 切 Tab；内容区左右滑翻图书馆/书城页；顶栏点源名换源、点其他区域或下滑开快捷面板。

  生命周期由 main.lua 驱动，不继承 ui/lifecycle.lua（Desktop 已经是 InputContainer）：
    onCreate → onStart → onResume
    onPause → onStop → onDestroy

@module koplugin.book.ui.desktop
--]]

local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local UIManager = require("ui/uimanager")
local logger = require("utils.log")
local Perf = require("utils.perf")
local _ = require("gettext")
local Screen = Device.screen

local Home = require("ui.desktop.home")
local Library = require("ui.desktop.library")
local StorePage = require("ui.desktop.store")
local Insight = require("ui.desktop.insight")
local Settings = require("ui.desktop.settings")
local Detail = require("ui.desktop.detail")
local NativePanel = require("ui.panel.native")
local TopBar = require("ui.components.topbar")
local BottomBar = require("ui.components.bottombar")
local UI = require("ui.components.bookui")
local BookStore = require("book.store")

local Desktop = InputContainer:extend{
    name = "book_desktop",
    covers_fullscreen = true,
    plugin = nil,
    source = nil,
    tab = "home",
    filter = nil,
}

--- 首页状态作废：source 层拿到 desktop 就能刷首页，不用反向 require UI。
function Desktop:invalidateHome()
    if self.home then self.home:invalidate() end
end

--- 向已创建的子组件广播业务事件，不消费 KOReader 手势事件。
---@param event string|table
---@param payload any
function Desktop:onEvent(event, payload)
    if self._closed then return end
    for _, key in ipairs({ "topbar", "bottombar", "home", "library", "store", "insight", "settings", "detail" }) do
        local child = self[key]
        if child and child.onEvent then
            child:onEvent(event, payload)
        end
    end
end

function Desktop:refreshHome(reason)
    if self.home then self.home:refreshData(reason) end
end

--- 按数据源能力生成 Desktop 底栏 Tab。
---@param source table|nil
---@return table
local function desktopTabs(source)
    local tabs = {
        { id = "home", text = _("首页"), icon = "home" },
        { id = "library", text = _("图书馆"), icon = "local_library" },
    }
    local caps = source and source.capabilities and source:capabilities() or {}
    if caps.store or (source and type(source.importBookAsync) == "function") then
        table.insert(tabs, { id = "store", text = _("书城"), icon = "storefront" })
    end
    if caps.insight then
        table.insert(tabs, { id = "stats", text = _("统计"), icon = "bar_chart" })
    end
    table.insert(tabs, { id = "settings", text = _("设置"), icon = "settings" })
    return tabs
end

--- 当前 tab 不在 tabs 列表中则回退 home（换源 / 能力变化后调用）。
---@param self table
local function clampTab(self)
    for _, t in ipairs(self._tabs) do
        if t.id == self.tab then
            return
        end
    end
    self.tab = "home"
end

-- 换源和关桌面都必须全部取消（漏一个就是关了页还在跑网络+写库）
local FETCH_JOB_KEYS = {
    "_books_sync_cancel",
    "_stats_sync_cancel",
}

local MAINTENANCE_JOB_KEYS = {
    "_cache_size_job",
    "_cache_clear_job",
    "_local_cleanup_job",
}

---@param self table
---@param keys string[]
local function cancelJobs(self, keys)
    for _, key in ipairs(keys) do
        local job = self[key]
        if type(job) == "table" and type(job.cancel) == "function" then
            pcall(function() job:cancel() end)
        elseif type(job) == "function" then
            pcall(job)
        end
        self[key] = nil
    end
end

--- 初始化手势区与默认分页状态，再 onCreate 画出第一帧。
function Desktop:init()
    self._tabs = desktopTabs(self.source)
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.source_generation = self.source_generation or 0
    self.tab = self.tab or "home"
    self.home = Home.new(self)
    self.library = Library.new(self)
    self.store = StorePage.new(self)
    self.insight = Insight.new(self)
    self.settings = Settings.new(self)
    self.topbar = TopBar.new(self)
    self.bottombar = BottomBar.new()
    clampTab(self)
    self._closed = false
    self.ges_events = {
        SwipeTopBar = {
            GestureRange:new{
                ges = "swipe",
                range = function()
                    return Geom:new{
                        x = 0,
                        y = 0,
                        w = Screen:getWidth(),
                        h = UI.topBarH(),
                    }
                end,
            },
        },
        TapTopBar = {
            GestureRange:new{
                ges = "tap",
                range = function()
                    return Geom:new{
                        x = 0,
                        y = 0,
                        w = Screen:getWidth(),
                        h = UI.topBarH(),
                    }
                end,
            },
        },
        TapBar = {
            GestureRange:new{
                ges = "tap",
                range = function()
                    local h = UI.barH()
                    return Geom:new{
                        x = 0,
                        y = Screen:getHeight() - h,
                        w = Screen:getWidth(),
                        h = h,
                    }
                end,
            },
        },
        Swipe = {
            GestureRange:new{
                ges = "swipe",
                range = function()
                    return Geom:new{
                        x = 0,
                        y = UI.topBarH(),
                        w = Screen:getWidth(),
                        h = Screen:getHeight() - UI.barH() - UI.topBarH(),
                    }
                end,
            },
        },
    }
    self:onCreate()
end

--- 创建：挂长期对象，画出第一帧。启动由 main.lua 在 show 之后调用。
function Desktop:onCreate()
    if self.topbar then self.topbar:onCreate() end
    self:rebuild()
end

--- 启动：通知顶栏开始心跳。
function Desktop:onStart()
    if self._closed or self._started then return end
    self._started = true
    if self.topbar then self.topbar:onStart() end
end

--- 恢复工作：通知顶栏与首页。同一轮事件只处理一次。
function Desktop:onResume()
    if self._closed or self._resume_lock then return end
    self._resume_lock = true
    UIManager:nextTick(function() self._resume_lock = false end)
    if self.topbar then self.topbar:onResume() end
    if self.home then self.home:onResume() end
    if self.tab ~= "home" and self.plugin and self.plugin.emitToSource then
        self.plugin:emitToSource("desktop_resume", self)
    end
end

--- 暂停：通知顶栏停心跳，桌面仍在。
function Desktop:onPause()
    if self.topbar then self.topbar:onPause() end
end

--- 停止：停顶栏心跳，并停掉各 Tab 的在飞工作。
function Desktop:onStop()
    if self.topbar then self.topbar:onStop() end
    if self.home then self.home:onStop() end
    if self.library then self.library:onStop() end
    if self.store then self.store:onStop() end
    if self.insight then self.insight:onStop() end
    self._started = false
end

--- 取消在飞请求，不拆窗体。
function Desktop:onCancel()
    cancelJobs(self, FETCH_JOB_KEYS)
    cancelJobs(self, MAINTENANCE_JOB_KEYS)
    if self.home then self.home:onCancel() end
    if self.library then self.library:onCancel() end
    if self.store then self.store:onCancel() end
    if self.insight then self.insight:onCancel() end
    if self.detail then self.detail:onCancel() end
end

--- 销毁：停时钟，释放监听、在飞任务和浮层。
function Desktop:onDestroy()
    if self._closed then return end
    self._closed = true
    if self.topbar then self.topbar:onDestroy() end
    self:onCancel()
    self.ges_events = nil
    if self.panel then
        local panel = self.panel
        self.panel = nil
        pcall(UIManager.close, UIManager, panel)
    end
    if self.detail then
        pcall(function()
            self.detail._closed = true
            self.detail.ges_events = nil
            UIManager:close(self.detail)
        end)
        self.detail = nil
    end
    if self._filter_root then
        pcall(UIManager.close, UIManager, self._filter_root)
        self._filter_root = nil
    end
    if self._filter_menu then
        pcall(UIManager.close, UIManager, self._filter_menu)
        self._filter_menu = nil
    end
end

--- 顶栏向下滑：打开 KOReader 原生菜单的 Book 快捷 Tab。
---@param _ any
---@param ges_ev table|nil
---@return boolean
function Desktop:onSwipeTopBar(_, ges_ev)
    return self.topbar:onSwipe(_, ges_ev)
end

--- 顶栏点击：缓存指标打开任务列表，源名区域切换数据源，其余区域打开原生快捷面板 Tab。
---@param _ any
---@param ges table|nil
---@return boolean
function Desktop:onTapTopBar(_, ges)
    return self.topbar:onTap(_, ges)
end


--- 内容区高度（扣除顶栏 + 底栏）。
---@return number
function Desktop:contentHeight()
    return math.max(1, Screen:getHeight() - UI.barH() - UI.topBarH())
end

--- 传给各 Tab 的上下文：plugin / source / desktop / filter。
---@return table
function Desktop:ctx()
    return {
        width = self.dimen.w,
        height = self:contentHeight(),
        plugin = self.plugin,
        source = self.source,
        desktop = self,
        filter = self.library.filter,
    }
end

--- 底栏点击：按 x 落点切换 Tab。
---@param _ any
---@param ges table|nil
---@return boolean
function Desktop:onTapBar(_, ges)
    if not ges or not ges.pos then return false end
    local tabs = self._tabs or desktopTabs(self.source)
    local bh = UI.barH()
    if ges.pos.y < self.dimen.h - bh then return false end
    local idx = math.floor(ges.pos.x * #tabs / self.dimen.w) + 1
    if idx < 1 then idx = 1 end
    if idx > #tabs then idx = #tabs end
    self:switchTab(tabs[idx].id)
    return true
end

--- 内容区左右滑：图书馆/书城翻页（不消费底栏区）。
---@param _ any
---@param ges_ev table|nil
---@return boolean
function Desktop:onSwipe(_, ges_ev)
    if type(ges_ev) ~= "table" or not ges_ev.direction then return true end
    if ges_ev.pos and ges_ev.pos.y >= self.dimen.h - UI.barH() then return true end
    local direction = BD.flipDirectionIfMirroredUILayout(ges_ev.direction)
    -- 不下滑关闭：内容区任意 south 都关太容易误触；退出走设置
    if self.tab == "library" then
        if direction == "west" then
            self.library:gotoPage(self.library.page + 1)
        elseif direction == "east" then
            self.library:gotoPage(self.library.page - 1)
        end
    elseif self.tab == "store" then
        if direction == "west" then
            self.store:gotoPage((self.store.page or 1) + 1)
        elseif direction == "east" then
            self.store:gotoPage((self.store.page or 1) - 1)
        end
    end
    return true
end

--- 切换底栏 Tab 并重建；进页时清对应缓存状态。
---@param id string
function Desktop:switchTab(id)
    if id == "library" and self.tab ~= "library" then
        self.library.state = nil
    end
    if id == "store" and self.tab ~= "store" then
        self.store.state = nil
    end
    if id == "settings" then
        self.settings:reset()
        self._cache_size_label = nil
    end
    if id == "stats" and self.tab ~= "stats" then
        self.insight.ui_page = 1
        self.insight.state = nil
        self.insight.loaded = false
    end
    self.tab = id
    if id == "home" then
        -- 进首页一律刷新一遍：清状态 + rebuild + 通知源查书架。
        self.home:refreshOnEnter()
        return
    end
    self:rebuild()
end

--- 切换设置子页并重建；页码重置到第一页。
---@param sub string|nil 子页标识；nil 回到设置主菜单
---@param parent string|nil 返回时的父级子页
function Desktop:showSettingsSub(sub, parent)
    self.settings:showSub(sub, parent)
end

--- 数据源切换：取消在飞请求、清各 Tab 缓存、回退不支持的 Tab 并重建。
---@param source BookSource|nil
function Desktop:sourceChanged(source)
    self.source_generation = (self.source_generation or 0) + 1
    self:onCancel()
    if self.library then self.library:reset() end
    if self.store then self.store:reset() end
    if self.insight then self.insight:reset() end
    if self.settings then self.settings:reset() end
    self._books_sync_pending = false
    self._books_sync_request = nil
    self._stats_sync_pending = false
    self._stats_sync_request = nil
    -- 旧页面在飞封面随 rebuild 里 old:free() 逐张取消；已落盘缓存保留。
    self.source = source
    self._tabs = desktopTabs(source)
    clampTab(self)
    if self.home then self.home:invalidate() end
    if self.tab ~= "home" then
        self:rebuild()
    end
end

--- 重建顶栏 + 内容 + 底栏。
function Desktop:rebuild()
    local started_at = Perf.now()
    pcall(function()
        require("utils.font").applyCurrent()
    end)
    local ok, err = pcall(function()
        local sw = Screen:getWidth()
        local sh = Screen:getHeight()
        self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
        local content
        if true then -- 临时诊断：只保留顶栏
            content = WidgetContainer:new{}
        elseif self.tab == "home" then
            content = self.home:content()
        elseif self.tab == "library" then
            content = self.library:content()
        elseif self.tab == "store" then
            content = self.store:content()
        elseif self.tab == "stats" then
            content = self.insight:content()
        else
            content = self.settings:build()
        end
        local content_h = self:contentHeight()
        local top_h = UI.topBarH()
        if content.dimen then
            content.dimen.w = sw
            content.dimen.h = content_h
        else
            content.dimen = Geom:new{ w = sw, h = content_h }
        end
        content.overlap_offset = { 0, top_h }

        local top = self.topbar:build()
        top.overlap_offset = { 0, 0 }

        self._tabs = desktopTabs(self.source)
        clampTab(self)
        local bar = WidgetContainer:new{ dimen = Geom:new{ w = sw, h = UI.barH() } }
        bar.overlap_offset = { 0, sh - UI.barH() }

        local root = OverlapGroup:new{
            dimen = Geom:new{ w = sw, h = sh },
            content,
            top,
            bar,
        }
        local frame = FrameContainer:new{
            bordersize = 0,
            padding = 0,
            margin = 0,
            background = Blitbuffer.COLOR_WHITE,
            root,
        }
        -- 先建新树、后释放旧树。反过来的话，页面构建抛错时 self[1] 已经是被 free
        -- 过的树，接下来照样会被 paintTo（下面只 return，不清 self[1]）。
        -- 旧树必须显式释放：里面的图片 asyncBox 只在 free 时取消在飞下载/解码，
        -- 否则每次切 Tab 都留下一批解好的 BlitBuffer 挂在孤立 widget 上等 GC。
        local old = self[1]
        self[1] = frame
        if old and old.free then
            old:free()
        end
    end)
    logger.dbg("book.perf desktop.rebuild", Perf.elapsedMs(started_at), "ms",
        self.tab or "-", ok and "ok" or "failed")
    if not ok then
        logger.err("book desktop rebuild failed:", err)
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{ text = _("桌面构建失败:\n") .. tostring(err) })
        return
    end
    UIManager:setDirty(self, "ui")
end

--- 只换顶栏并区域刷新；分钟心跳禁止整页 rebuild / full flash。
function Desktop:refreshTopBar()
    logger.dbg("desktop refreshTopBar")
    local root = self[1] and self[1][1]
    if not root or not root[2] then
        self:rebuild()
        return
    end
    local ok, err = pcall(function()
        local top = self.topbar:build()
        top.overlap_offset = { 0, 0 }
        if root[2].free then
            root[2]:free()
        end
        root[2] = top
    end)
    if not ok then
        logger.err("book desktop refreshTopBar failed:", err)
        self:rebuild()
        return
    end
    UIManager:setDirty(self, "ui", Geom:new{
        x = 0,
        y = 0,
        w = Screen:getWidth(),
        h = UI.topBarH(),
    })
end

--- 原地刷新首页时钟；不重建整页，避免重置封面和异步图片任务。
function Desktop:refreshHomeClock()
    if self.tab ~= "home" or type(self.home.clock_refresh) ~= "function" then
        return
    end
    self.home.clock_refresh()
    local region = self.home.clock_region
    if not region then return end
    UIManager:setDirty(self, "ui", Geom:new{
        x = region.x,
        y = UI.topBarH() + region.y,
        w = region.w,
        h = region.h,
    })
end

--- 打开书籍详情浮层。
---@param book table
function Desktop:showDetail(book)
    if self.detail then
        UIManager:close(self.detail)
        self.detail = nil
    end
    if book.source_id and book.source_id ~= "zlib" then
        BookStore.rememberMany({ book })
    end
    local desk = self
    self.detail = Detail:new{
        book = book,
        plugin = self.plugin,
        source = self.source,
        desktop = self,
        store_preview = self.tab == "store",
        covers_fullscreen = true,
        close_callback = function()
            local dirty = desk.detail and desk.detail._dirty
            desk.detail = nil
            if desk._closed then
                return
            end
            if dirty then
                -- 详情里改过数据（编辑/刮削）：列表与首页缓存已失效，重建触发重拉
                if desk.library then desk.library.state = nil end
                if desk.home then desk.home:invalidate() end
                if desk.tab ~= "home" then
                    desk:rebuild()
                end
            else
                UIManager:setDirty(desk, "ui")
            end
        end,
    }
    UIManager:show(self.detail)
    UIManager:setDirty(self.detail, "ui")
end

--- KOReader 关窗入口，不是生命周期。关窗前走完 pause/stop/destroy。
---@return boolean
function Desktop:onClose()
    logger.info("book.desktop close")
    if self._closed then return true end
    self:onPause()
    self:onStop()
    self:onDestroy()
    UIManager:close(self)
    if self.close_callback then
        pcall(self.close_callback)
    end
    -- 桌面关闭后重绘 FileManager；这是普通 UI 切换，不能触发 Kindle 全屏闪烁。
    UIManager:nextTick(function()
        UIManager:setDirty("all", "ui")
        local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
        if ok and FileManager and FileManager.instance then
            UIManager:setDirty(FileManager.instance, "ui")
        end
    end)
    return true
end

--- Widget 关闭回调：若尚未走完生命周期，补齐停止与销毁。
function Desktop:onCloseWidget()
    if self._closed then return end
    self:onPause()
    self:onStop()
    self:onDestroy()
end

return Desktop
