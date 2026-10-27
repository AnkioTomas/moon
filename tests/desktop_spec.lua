---@diagnostic disable: missing-fields
--[[--
桌面壳：三层（内容 / 顶栏 / 底栏）拼装；active 才刷屏；外壳签名变了整壳重建全刷，
否则只换内容层与底栏层、只刷顶栏以下；updateTopbar 只换顶栏、只刷顶栏；
底栏点当前格吞掉点按不切页；换源重算 Tab 回首页；Destroy 补齐 Pause 且只做一次。
@module tests.desktop_spec
--]]
local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")
Kit.sections.store = {}
Kit.sections.extensions = {}
Kit.sections.subscribe = {}
Kit.sections.clock = { ntp_auto = false }
Kit.sections.desktop = {}

local Widget = require("ui/widget/widget")

local log, freed = {}, {}
local function drain() local out = table.concat(log, ","); log = {}; return out end

local function page(name)
    local P = {}
    P.__index = P
    function P:new(o) return setmetatable(o, self) end
    function P:updateView()
        local w = Widget:new{ page = self:id() }
        function w:free() freed[#freed + 1] = self end
        self.root = w
        return w
    end
    function P.providers() return Kit.sections.store.zlib_enabled and { {} } or {} end
    function P:id() return self.name or name end
    function P:activate(changed) log[#log + 1] = self:id() .. ".resume" .. (changed and "!" or "") end
    function P:deactivate() log[#log + 1] = self:id() .. ".pause" end
    function P:destroy() log[#log + 1] = self:id() .. ".destroy" end
    function P:onEvent(event, payload)
        log[#log + 1] = self:id() .. ":" .. event
        self.last_payload = payload
    end
    return P
end
for _, name in ipairs({ "home", "library", "store", "insight" }) do
    package.preload["desktop.pages." .. name] = function() return page(name) end
end
package.preload["desktop.pages.setting"] = function() return page("settings") end
local synced = {}
package.preload["desktop.sync"] = function()
    return { open = function(desk) synced[#synced + 1] = desk end }
end

local top_builds = 0
package.preload["desktop.topbar"] = function()
    local T = page("topbar")
    function T.height() return 30 end
    function T:build(width)
        top_builds = top_builds + 1
        local w = Widget:new{ dimen = { w = width, h = 30 }, top = top_builds }
        function w:free() freed[#freed + 1] = self end
        return w
    end
    return T
end

-- 扩展点（真机由各 feature 的 init 登记；桌面只认通用挂点）
local Ext = require("utils.extension")
local panels, checks = {}, {}
Ext.add("quickpanel.show", function(id) panels[#panels + 1] = id end)
local popups = {}
Ext.add("desktop.tabs", { id = "extensions", text = "拓展", icon = "extension", after = "insight",
    enabled = function() return Kit.sections.extensions.enabled and true or false end,
    tap = function(desk, rect) popups[#popups + 1] = { plugin = desk.plugin, rect = rect } end })
local sub_pages = 0
Ext.add("desktop.tabs", { id = "subscribe", text = "订阅", icon = "subscriptions", after = "library",
    enabled = function() return Kit.sections.subscribe.enabled and true or false end,
    create = function(opts)
        sub_pages = sub_pages + 1
        return package.loaded["features.subscribe.page"]:new(opts)
    end })
Ext.add("desktop.activated", function(desk) checks[#checks + 1] = desk.plugin.path end)
package.preload["utils.log"] = function()
    return { dbg = function() end, info = function() end, error = function() end, flush = function() end }
end

local Tabbar = require("ui.themes.widgets.tabbar")
local Desktop = require("desktop")

local plugin = { path = "/plugins/book.koplugin" }
local desk = Desktop:new{ plugin = plugin }
plugin.desktop = desk
local BAR_H = Tabbar.height()

local function tabs() return Kit.taps(desk.layers[3]) end
local function ids()
    local out = {}
    for _, t in ipairs(desk._tabs) do out[#out + 1] = t.id end
    return table.concat(out, ",")
end

do -- 首帧：三层就位，未 resume 不刷屏
    Assert.eq(desk.tab, "home")
    Assert.eq(ids(), "home,library,insight,settings")
    Assert.eq(desk.layers[1].page, "home")
    Assert.eq(desk.layers[1].dimen.w, 600)
    Assert.eq(desk.layers[1].dimen.h, 800 - 30 - BAR_H)
    Assert.eq(desk.layers[1].overlap_offset[2], 30)
    Assert.eq(desk.layers[2].top, 1)
    Assert.eq(desk.layers[3].overlap_offset[2], 800 - BAR_H)
    Assert.eq(desk:contentHeight(), 800 - 30 - BAR_H)
    Assert.eq(desk[1][1], desk.layers)
    Assert.len(Kit.dirty, 0)
    Assert.len(tabs(), 4)
end

do -- Resume：只唤醒顶栏与当前页，触发静默更新检查，并 Sync.open 扫盘
    local n = #synced
    desk:activate()
    Assert.is_true(desk.active)
    Assert.eq(drain(), "topbar.resume,home.resume")
    Assert.eq(checks[1], "/plugins/book.koplugin")
    Assert.eq(#synced, n + 1, "回前台触发书架同步")
    Assert.eq(synced[#synced], desk)
end

do -- 点底栏切页：旧页 pause、新页 resume(changed)，只换内容 / 底栏层，只刷顶栏以下
    local old_content, old_bar = desk.layers[1], desk.layers[3]
    freed = {}
    tabs()[2]:onTapThemeArea()
    Assert.eq(desk.tab, "library")
    Assert.eq(drain(), "home.pause,library.resume!")
    Assert.eq(desk.layers[1].page, "library")
    Assert.is_true(desk.layers[3] ~= old_bar)
    Assert.eq(freed[1], old_content)
    Assert.eq(desk.layers[2].top, 1, "切页不重建顶栏")
    local d = Kit.dirty[#Kit.dirty]
    Assert.eq(d.widget, desk)
    Assert.eq(d.region.y, 30)
    Assert.eq(d.region.h, 800 - 30)
end

do -- 点当前格：吞掉点按，不回调、不重建
    local n, before = #Kit.dirty, desk.layers[1]
    Assert.is_true(tabs()[2]:onTapThemeArea())
    Assert.eq(desk.tab, "library")
    Assert.eq(#Kit.dirty, n)
    Assert.eq(desk.layers[1], before)
    Assert.eq(drain(), "")
end

do -- 顶栏读数变化：只换第 2 层，只刷顶栏
    local old_top, content = desk.layers[2], desk.layers[1]
    desk:updateTopbar()
    Assert.eq(desk.layers[2].top, 2)
    Assert.eq(freed[#freed], old_top)
    Assert.eq(desk.layers[1], content)
    local d = Kit.dirty[#Kit.dirty]
    Assert.eq(d.region.y, 0)
    Assert.eq(d.region.h, 30)
end

do -- 外壳签名（主题）变了：整壳重建，全刷
    local old_root = desk[1]
    Kit.use("soft")
    desk:updateView()
    Assert.not_nil(desk[1])
    Assert.is_true(desk[1] ~= old_root)
    Assert.eq(desk.layers[2].top, 3, "整壳重建连顶栏一起")
    Assert.is_nil(Kit.dirty[#Kit.dirty].region)
    Kit.use("paper")
    desk:updateView()
end

do -- 换色板（主色相同也不能只看 accent）：整壳重建，顶栏不残留上一套色板
    Kit.color_enabled = true
    Kit.display.theme_preset = "ocean"
    desk:updateView()
    local top = desk.layers[2].top
    Kit.display.theme_preset = "aurora"
    desk:updateView()
    Assert.is_true(desk.layers[2].top > top, "换色板连顶栏一起重建")
    Kit.display.theme_preset = nil
    Kit.color_enabled = false
    desk:updateView()
end

do -- 当前 Tab 被关掉（书城开关）：回退首页
    Kit.sections.store.zlib_enabled = true
    desk:switchTab("store")
    Assert.eq(ids(), "home,library,store,insight,settings")
    Assert.eq(desk.tab, "store")
    Kit.sections.store.zlib_enabled = nil
    desk:updateView()
    Assert.eq(desk.tab, "home")
    Assert.eq(desk.layers[1].page, "home")
    Assert.eq(ids(), "home,library,insight,settings")
    drain()
end

do -- 拓展格：开关打开才出现；点它在格子上弹层，不切页
    Kit.sections.extensions.enabled = true
    desk:updateView()
    Assert.eq(ids(), "home,library,insight,extensions,settings")
    local cell = tabs()[4]
    Assert.is_true(cell:onTapThemeArea())
    Assert.eq(desk.tab, "home")
    Assert.len(popups, 1)
    Assert.eq(popups[1].plugin, plugin)
    Assert.eq(popups[1].rect, cell.dimen)
    Kit.sections.extensions.enabled = nil
    desk:updateView()
    Assert.eq(ids(), "home,library,insight,settings")
    drain()
end

do -- 统计入口可隐藏；当前统计页回首页，扩展仍可用，重新开启恢复入口。
    desk:switchTab("insight")
    Kit.sections.desktop.insight_enabled = false
    Kit.sections.extensions.enabled = true
    desk:updateView()
    Assert.eq(ids(), "home,library,extensions,settings")
    Assert.eq(desk.tab, "home")
    Assert.eq(desk.layers[1].page, "home")
    desk:switchTab("insight")
    Assert.eq(desk.tab, "home", "隐藏后不能通过切页重新显示")
    Kit.sections.desktop.insight_enabled = true
    Kit.sections.extensions.enabled = nil
    desk:updateView()
    Assert.eq(ids(), "home,library,insight,settings")
    desk:switchTab("insight")
    Assert.eq(desk.layers[1].page, "insight")
    desk:switchTab("home")
    drain()
end

do -- 订阅格：总开关打开才出现在图书馆旁；关掉时在订阅页会退回首页
    package.loaded["features.subscribe.page"] = page("subscribe")
    Kit.sections.subscribe.enabled = true
    desk:updateView()
    Assert.eq(ids(), "home,library,subscribe,insight,settings")
    desk:switchTab("subscribe")
    Assert.eq(desk.tab, "subscribe")
    Assert.eq(desk.layers[1].page, "subscribe")
    Kit.sections.subscribe.enabled = nil
    desk:updateView()
    Assert.eq(desk.tab, "home")
    Assert.eq(ids(), "home,library,insight,settings")
    Assert.is_nil(desk.ext_pages.subscribe, "关掉后订阅页释放")
    Assert.eq(sub_pages, 1, "页按需建一次")
    drain()
end

do -- 非法 Tab 忽略
    local n = #Kit.dirty
    desk:switchTab("nope")
    Assert.eq(desk.tab, "home")
    Assert.eq(#Kit.dirty, n)
end

do -- 换源：广播给各子件，留在当前页签
    desk:switchTab("settings")
    drain()
    local source = { id = "next" }
    local synced_before = #synced
    package.loaded["source.registry"] = { current = function() return source end }
    desk:onSourceChanged()
    package.loaded["source.registry"] = nil
    Assert.eq(desk.source, source)
    Assert.eq(#synced, synced_before + 1)
    Assert.eq(synced[#synced], desk, "换源后对新源做桌面打开同步")
    Assert.eq(ids(), "home,library,insight,settings")
    Assert.eq(desk.tab, "settings")
    drain()
    desk:switchTab("home")
    drain()
    Assert.eq(desk.store.last_payload, source)
end

do -- KOReader 系统事件沿控件树直达顶栏控件，桌面不截留、不转成子页 onEvent
    local Event = require("ui/event")
    Assert.is_nil(desk.onCharging)
    Assert.is_nil(desk.onNetworkDisconnected)
    desk:handleEvent(Event:new("Charging"))
    Assert.eq(drain(), "")
end

do -- 手势：内容区左右滑只给当前页；顶栏下滑开快捷面板；底栏空白吞掉
    Assert.is_true(desk:onSwipe(nil, { direction = "west" }))
    Assert.eq(drain(), "home:swipe")
    Assert.eq(desk.home.last_payload.direction, "west")
    Assert.is_true(desk:onSwipeTopBar(nil, { direction = "north" }))
    Assert.len(panels, 0)
    desk:onSwipeTopBar(nil, { direction = "south" })
    Assert.eq(panels[1], "desktop")
    Assert.is_true(desk:onTapBar())
    -- 对角滑动是 KOReader 截图手势：内容区与顶栏都不吞，放行给下层。
    Assert.is_false(desk:onSwipe(nil, { direction = "northeast" }))
    Assert.is_false(desk:onSwipeTopBar(nil, { direction = "southwest" }))
end

do -- 系统 Suspend 广播直达桌面 → Pause，之后不刷屏
    desk:handleEvent(require("ui/event"):new("Suspend"))
    Assert.is_false(desk.active)
    Assert.eq(drain(), "topbar.pause,home.pause,library.pause,store.pause,insight.pause,settings.pause")
    local n = #Kit.dirty
    desk:updateView()
    desk:updateTopbar()
    Assert.eq(#Kit.dirty, n)
end

do -- Destroy：活跃时先补 Pause；关叠层、清 plugin.desktop；只做一次，之后事件与刷新全忽略
    desk:activate()
    drain()
    local overlay_closed = false
    desk.settings_overlay = { close = function() overlay_closed = true end, updateView = function() end }
    desk:onClose()
    Assert.is_true(desk.closed)
    Assert.is_true(overlay_closed)
    Assert.is_nil(plugin.desktop)
    Assert.eq(Kit.closed[#Kit.closed], desk)
    local out = drain()
    Assert.matches(out, "^topbar%.pause,home%.pause")
    Assert.matches(out, "topbar%.destroy,home%.destroy,library%.destroy,store%.destroy,insight%.destroy,settings%.destroy$")
    desk:handleEvent(require("ui/event"):new("Exit"))
    desk:onEvent("home_changed")
    desk:activate()
    desk:updateView()
    Assert.eq(drain(), "")
    Assert.is_false(desk.active)
end

do -- Desktop.open：无源只提示；有源建桌面、显示、Resume、通知源；再开先销毁旧桌面
    local current = nil
    package.loaded["source.registry"] = { current = function() return current end }
    package.loaded["utils.paths"] = { ensureLayout = function() end }
    package.loaded["ui/widget/infomessage"] = { new = function(_, o) return o end }
    local shown_before = #Kit.shown
    local host = { path = "/plugins/book.koplugin", ui = {} }
    Desktop.open(host)
    Assert.is_nil(host.desktop)
    Assert.eq(#Kit.shown, shown_before + 1)
    Assert.eq(Kit.shown[#Kit.shown].text, "当前数据源不可用", "无源弹提示")

    current = { id = "local" }
    local synced_before = #synced
    Desktop.open(host)
    local first = host.desktop
    Assert.not_nil(first)
    Assert.eq(Kit.shown[#Kit.shown], first)
    Assert.is_true(first.active, "打开即 Resume")
    Assert.eq(#synced, synced_before + 1)
    Assert.eq(synced[#synced], first, "打开后后台同步")

    Desktop.open(host)
    Assert.is_true(first.closed, "重开先销毁旧桌面")
    Assert.eq(Kit.closed[#Kit.closed], first)
    Assert.is_true(host.desktop ~= first)
    drain()
end

do -- 开机自动开桌面：按启动项、进程内只开一次；Reader 实例与已有桌面不开。重新 require = 进程重启
    local on_start = true
    package.loaded["menu"] = { openOnStart = function() return on_start end }
    local function boot()
        package.loaded["desktop"] = nil
        local D = require("desktop")
        local opened = {}
        D.open = function(p) opened[#opened + 1] = p end
        return D, opened
    end
    local D, opened = boot()
    D.autoOpen({ ui = { document = {} } })
    Assert.len(opened, 0, "Reader 实例不自动开")
    D.autoOpen({ ui = {}, desktop = {} })
    Assert.len(opened, 0, "已有桌面不重开")
    local fm = { ui = {} }
    D.autoOpen(fm)
    D.autoOpen(fm)
    Assert.len(opened, 1, "进程内只自动开一次")
    Assert.eq(opened[1], fm)
    on_start = false
    D, opened = boot()
    D.autoOpen({ ui = {} })
    Assert.len(opened, 0, "启动项不是月读不自动开")

    -- 启动即开桌面：FM 改列 KOReader 数据目录；只在进程首个 FM、启动项为月读时
    package.loaded["datastorage"] = { getDataDir = function() return "/data" end }
    on_start = true
    D, opened = boot()
    local p = { ui = {} }
    D.startInDataDir(p)
    Assert.eq(p.ui.root_path, "/data/ko-empty", "启动即开桌面列空目录")
    local reader = { ui = { document = {} } }
    D.startInDataDir(reader)
    Assert.is_nil(reader.ui.root_path, "Reader 实例不动")
    D.autoOpen({ ui = {} })
    local later = { ui = {} }
    D.startInDataDir(later)
    Assert.is_nil(later.ui.root_path, "启动已过不再改")
    on_start = false
    D = boot()
    local off = { ui = {} }
    D.startInDataDir(off)
    Assert.is_nil(off.ui.root_path, "启动项不是月读不改")

    -- 阅读中回桌面重建 FM：列空目录，lastdir 还原
    local saved = { lastdir = "/books" }
    _G.G_reader_settings = {
        readSetting = function(_s, k) return saved[k] end,
        saveSetting = function(_s, k, v) saved[k] = v end,
        isTrue = function() return false end,
    }
    local FM = { showFiles = function(self, path) self.instance = { listed = path } end }
    package.loaded["apps/filemanager/filemanager"] = FM
    D = boot()
    Assert.eq(D.ensureFileManager().listed, "/data/ko-empty")
    Assert.eq(saved.lastdir, "/books", "lastdir 不被改")
end

return true
