--[[--
Feature 生命周期分发。

加载：main.lua 顶层调 `Features.load()`（不点名任何 feature），按 list 顺序 require 各 feature 的 init。
核心下层不认识 feature：feature 在自己 init 的模块顶层往 `utils.extension` 的通用挂点登记（底栏页签、
桌面前台 / 打开后、快捷面板、顶栏读数、划词菜单、阅读器就绪 / 文档设置 / 偏好、页内标记 class 等，清单见该模块 POINTS）；
setting.lua / topbar.lua 两种约定文件由加载器代为登记到 setting.entries / topbar.items。

`list` 是唯一登记处：条目为目录名，对应模块 `features.<name>`；顺序即调用顺序
（monkey-patch 同一 KOReader 方法的 feature 靠它定先后），不扫目录。

钩子都是可选的模块函数，名字就是 KOReader 事件名（onCreate 除外），参数只有插件实例；
要分侧就看 `plugin.ui.document`（有文档 = 阅读器侧）。别用 `plugin.desktop`：那是桌面窗口，FM 侧也常为 nil。

  onCreate(plugin)            每个插件实例 init 时（FM / Reader 各一份），feature 自行防重入
  onSuspend(plugin)           休眠前
  onResume(plugin)            唤醒后
  onExit(plugin)              KOReader 退出
  onNetworkConnected(plugin)  网络恢复
  onReaderReady(plugin)       阅读页就绪（reader/page.lua 发出，早于首绘 UpdatePos）

KOReader 事件（Dispatcher 动作、FrontlightStateChanged 这类广播）写进模块的 `events` 表：
键是事件名（不带 on），值是 `fn(plugin, ...)`；插件自身没处理的事件经 `Features.handleEvent` 转过来，
返回 true 即视为已处理、不再往后传。feature 不往插件实例上挂方法。

每个 feature 的钩子经 `ui.guard` 隔离：一个抛错弹错误页，不影响其余 feature。实现就在 `features/<name>/`，这里只登记生命周期钩子与 KOReader 事件。

下面四个约定文件都经 `Features.scan` 扫描目录收集（按目录名排序），不经本文件、不看 `list`：

可选 `features/<name>/setting.lua`（设置页收集）：
  - `defaults` / `keys`：本 feature 的配置键与默认值，落盘到 settings/<name>.lua，经 `utils.settings.get("features.<name>")` 读、
    `save("features.<name>")` 写（keys 是无默认值但要从旧分区迁移的持久键）。规则与核心拥有者相同，见 utils/settings.lua。
  - `entries(desktop)` 返回条目数组，按层级合并进设置页：`group` 挂到根页分组（导航页或直接放行），
    `parent` 往已有页面追加分节；每条带 `order`。格式与校验见 `desktop/pages/setting/tree.lua`。
    没有 entries 就不出现在设置页。`utils.settings` 读默认值也会加载它（阅读器侧也会），顶层别 require 界面模块。

可选 `features/<name>/events.lua`：返回 `{ [事件名] = fn(...) }`，订阅核心发出的数据事件（如 book_identity_changed），
由 `utils.event` 在插件 init 时登记。和模块里的 `events` 表（KOReader 事件）是两回事。

可选 `features/<name>/panel.lua`：`actions()` 返回数组，每条是一个快捷面板开关，`scope` 为 desktop 或 reader。
由快捷面板注册表（features/panel/actions/registry.lua）加载时收集，追加在该侧内置开关之后。

可选 `features/<name>/topbar.lua`：`items()` 返回桌面顶栏项数组（BookTopBarItem，见 desktop/topbar），
由顶栏首次用到时收集，追加在核心项之后；设置页的开关与预览读同一份数据。

onCreate 每次开书、关书都会再调（FM / Reader 各建实例），monkey-patch KOReader 的 feature 用模块级标记防重入。
只有写进 list 的才加载。新增 feature：复制 demo/ 为 <name>/ 删掉不用的钩子，加进 list，测试放 tests/features/<name>/；
demo/ 不登记、打包时剔除。

第三方 feature：KOReader 插件的 moon_source.lua 写 `provides.features = { setting, panel, topbar, events, hooks }`，
每个值是表，或插件内的模块名（字符串，用到时才 require）；形状与对应约定文件相同：
  setting = { entries = fn(desktop) }、panel = { actions = fn() }、topbar = { items = fn() }、
  events = { [数据事件名] = fn(...) }、hooks = { onReaderReady = fn(plugin) }。
`Features.external(kind)` 收集它们，由四个收集点（设置树、快捷面板注册表、桌面顶栏、main 传给 utils.event）追加在内置项之后。
只开放 onReaderReady：其余生命周期与 KOReader 事件第三方插件自己的实例就能收到，月读不转发；补丁与页内标记不开放。
规则：
  - 页面 / 开关 / 顶栏项 id 自动加 `<扩展 id>.` 前缀（已带则不重复加），撞名的记日志跳过；
  - 配置存 utils.settings.getSource(<扩展 id>)（settings/ext.<name>.lua，不参与旧分区迁移），别用 get / save；
  - 每个回调经 Features.try 隔离：出错只记日志（不弹错误页），读数类回调返回 nil，数据事件订阅方出错不中断核心派发；
  - 插件卸载后已保存的开关 / 顶栏 id 找不到就静默跳过；插件未加载完（extensionsReady 为假）时收集方不缓存。阅读会话、后台任务、源生命周期这类有返回值或顺序约束的核心编排不走这里，留在 main.lua。

@module koplugin.book.features
--]]

local Guard = require("ui.guard")
local Perf = require("utils.perf")

local Features = {}

local DIR = debug.getinfo(1, "S").source:match("^@(.*)/[^/]+$")
Features.DIR = DIR
local scanned = {}
local off = {} -- 用户停用的 feature（启动时由 Manage.apply 取得），目录扫描跳过

--- 扫描 features/ 下提供 `<file>.lua` 的目录名，按名字排序；每种文件本进程只扫一次。
---@param file string 约定文件名（不带 .lua），如 "setting" / "events" / "panel"
---@return string[]
function Features.scan(file)
    if scanned[file] then return scanned[file] end
    local lfs = require("libs/libkoreader-lfs")
    local names = {}
    for name in lfs.dir(DIR) do
        if name:sub(1, 1) ~= "." and not off[name] and lfs.attributes(DIR .. "/" .. name .. "/" .. file .. ".lua", "mode") == "file" then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    scanned[file] = names
    return names
end

--- 取某个 feature 的约定文件模块（名字来自 Features.scan），核心经端口拿到后用它，不自己拼模块路径。
---@param name string
---@param file string
---@return table
function Features.module(name, file)
    return require("features." .. name .. "." .. file)
end

-- 顺序即 onCreate 先后。bars / sidebar 没有 onCreate，排前面只影响设置页里的行序。
Features.list = {
    "clock", -- 最先：时区要在其它 feature 按本地时间算东西之前生效
    "nightmode",
    "panel",
    "azw3",
    "bars",
    "sidebar",
    "xray",
    "ai",
    "reviews",
    "rare",
    "translate",
    "reflow",
    "animation",
    "dictionary",
    "ocr",
    "baike",
    "lockscreen",
    "wallpaper",
    "passcode", -- 必须在 remote 之前：remote 的 onCreate / onResume 要看到已锁
    "ime",
    "remote",
    "update",
    "storage",
    "subscribe",
    "cookie",
    "extensions",
}

local External = require("utils.external")
local Ext = require("utils.extension")

-- 第三方挂点工具在核心 utils.external；这里保留旧名给 features 内部用。
Features.try = External.try
Features.wrap = External.wrap
Features.prefix = External.prefix
Features.external = External.collect

local loaded = false

--- 加载器：main.lua 顶层调一次（不点名任何 feature）。
---   0. 先把用户在「功能开关」里停用的 feature 从 list 去掉并记下（features/manage）；
---   1. 按 list 顺序 require 每个 feature 的 init：模块顶层自己往 utils.extension 的挂点登记；
---   2. 约定文件 setting.lua（有 entries 的）/ topbar.lua 代为登记到 setting.entries / topbar.items（按目录名）；
---   3. 把本层的 onReaderReady 分发登记到 reader.ready。
--- 重复调用无副作用。
function Features.load()
    if loaded then return end
    loaded = true
    off = Guard.call("feature manage apply", require("features.manage").apply, Features.list) or off
    for _idx, name in ipairs(Features.list) do
        local started_at = Perf.now()
        Guard.call("feature " .. name .. " load", require, "features." .. name)
        Perf.slow("feature load " .. name, started_at)
    end
    Features.registerConventions()
end

--- 约定文件代登记（load 的第 2、3 步；单测只要设置 / 顶栏条目时也可单独调）。
function Features.registerConventions()
    for _idx, name in ipairs(Features.scan("setting")) do
        if Features.module(name, "setting").entries then
            Ext.add("setting.entries", { name = name, entries = function(desktop)
                return Features.module(name, "setting").entries(desktop)
            end })
        end
    end
    for _idx, name in ipairs(Features.scan("topbar")) do
        Ext.add("topbar.items", function() return Features.module(name, "topbar").items() end)
    end
    Ext.add("reader.ready", function(plugin) Features.emit("onReaderReady", plugin) end)
end

---@param hook string
---@param plugin BookPlugin
function Features.emit(hook, plugin)
    for _idx, name in ipairs(Features.list) do
        local started_at = Perf.now()
        local fn = require("features." .. name)[hook]
        if fn then Guard.call("feature " .. name .. "." .. hook, fn, plugin) end
        Perf.slow("feature " .. name .. "." .. hook, started_at)
    end
    if hook ~= "onReaderReady" then return end
    for _idx, item in ipairs(Features.external("hooks")) do
        Features.try(item.id .. "." .. hook, item.mod[hook], plugin)
    end
end

-- handler 名（on + 事件名）→ { label, fn } 数组，首次分发时按 list 顺序建好。
local routes

---@param event table KOReader Event（handler / args）
---@param plugin BookPlugin
---@return boolean handled
function Features.handleEvent(event, plugin)
    if not routes then
        routes = {}
        for _idx, name in ipairs(Features.list) do
            for ev, fn in pairs(require("features." .. name).events or {}) do
                local handler = "on" .. ev
                routes[handler] = routes[handler] or {}
                table.insert(routes[handler], { label = "feature " .. name .. ".events." .. ev, fn = fn })
            end
        end
    end
    local list = routes[event.handler]
    if not list then return false end
    for _idx, route in ipairs(list) do
        if Guard.call(route.label, route.fn, plugin, unpack(event.args, 1, event.args.n)) then return true end
    end
    return false
end

--- 各 feature 的某个约定文件（如 events）按扫描顺序 require 出来；events 再追加第三方订阅方
--- （出错只记日志并当作成功，不中断核心派发、不触发回滚）。
---@param file string
---@return table[] listeners, boolean ready 第三方扩展已收全
function Features.listeners(file)
    local out = {}
    for _idx, name in ipairs(Features.scan(file)) do out[#out + 1] = require("features." .. name .. "." .. file) end
    if file ~= "events" then return out, true end
    local items, ready = Features.external("events")
    for _idx, item in ipairs(items) do
        local map = {}
        for event, fn in pairs(item.mod) do
            if type(event) == "string" and type(fn) == "function" then
                local label = item.id .. ".events." .. event
                map[event] = function(...)
                    Features.try(label, fn, ...)
                    return true
                end
            end
        end
        out[#out + 1] = map
    end
    return out, ready
end

return Features
